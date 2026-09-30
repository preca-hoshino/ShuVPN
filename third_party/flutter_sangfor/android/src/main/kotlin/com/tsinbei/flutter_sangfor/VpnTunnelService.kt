package com.tsinbei.flutter_sangfor

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.net.VpnService

/**
 * Foreground VpnService that establishes a TUN interface and hands the raw
 * file descriptor to the Dart side, which reads and writes it directly
 * through FFI. The app itself is NOT disallowed: the caller excludes the
 * tunnel node endpoints from the route list, which keeps the tunnel
 * transport on the underlying network while the app's own traffic
 * (including WebViews) is tunneled like everything else.
 *
 * The persistent notification doubles as a keep-alive and shows the
 * connection speed and uptime, mirroring common proxy clients.
 */
class VpnTunnelService : VpnService() {
    companion object {
        @Volatile
        var activeService: VpnTunnelService? = null
            private set

        private const val CHANNEL_ID = "flutter_sangfor_vpn"
        private const val NOTIFICATION_ID = 1
        private const val ACTION_DISCONNECT = "com.tsinbei.flutter_sangfor.DISCONNECT"
        private const val ACTION_NOTIFICATION_DELETED =
            "com.tsinbei.flutter_sangfor.NOTIFICATION_DELETED"
        private const val NOTIFICATION_GUARD_INTERVAL_MS = 30_000L
        private const val NOTIFICATION_REPOST_DELAY_MS = 1_000L

        fun start(context: Context) {
            val intent = Intent(context, VpnTunnelService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, VpnTunnelService::class.java))
        }
    }

    private val startedElapsed = SystemClock.elapsedRealtime()
    private val startedWallClock = System.currentTimeMillis()
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var notificationGuard: Runnable? = null
    private var notificationTitle = "VPN"
    private var disconnectLabel = "Disconnect"
    private var totalDown = 0L
    private var totalUp = 0L
    private var speedDown = 0L
    private var speedUp = 0L
    private var lastStatsAt = 0L

    override fun onCreate() {
        super.onCreate()
        activeService = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_DISCONNECT -> FlutterSangforPlugin.requestDisconnect()
            ACTION_NOTIFICATION_DELETED -> {
                // The notification was swiped away on an OEM build; bring
                // it back after a short beat.
                mainHandler.postDelayed(
                    { notifyUpdated() },
                    NOTIFICATION_REPOST_DELAY_MS,
                )
            }
        }
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        startNotificationGuard()
        return START_STICKY
    }

    override fun onDestroy() {
        stopNotificationGuard()
        activeService = null
        super.onDestroy()
    }

    /// Re-posts the notification when the user manages to swipe it away
    /// (stock Android pins ongoing foreground notifications, but some OEM
    /// builds allow dismissing them): the delete intent fires and the
    /// notification returns after about a second. A slow safety re-post
    /// covers builds that neither pin nor deliver the delete intent.
    private fun startNotificationGuard() {
        if (notificationGuard != null) return
        val guard = object : Runnable {
            override fun run() {
                notifyUpdated()
                mainHandler.postDelayed(this, NOTIFICATION_GUARD_INTERVAL_MS)
            }
        }
        notificationGuard = guard
        mainHandler.postDelayed(guard, NOTIFICATION_GUARD_INTERVAL_MS)
    }

    private fun stopNotificationGuard() {
        notificationGuard?.let { mainHandler.removeCallbacks(it) }
        notificationGuard = null
    }

    /** Updates the persistent notification with cumulative byte counters;
     * the per-second speed is derived from the previous sample. */
    fun updateStats(down: Long, up: Long) {
        val now = SystemClock.elapsedRealtime()
        if (lastStatsAt > 0L) {
            val elapsedMs = (now - lastStatsAt).coerceAtLeast(1L)
            speedDown = (down - totalDown).coerceAtLeast(0L) * 1000L / elapsedMs
            speedUp = (up - totalUp).coerceAtLeast(0L) * 1000L / elapsedMs
        }
        totalDown = down
        totalUp = up
        lastStatsAt = now
        notifyUpdated()
    }

    private fun notifyUpdated() {
        // Re-rendering while the screen is off burns cycles for nothing;
        // the next live sample refreshes the readout once the user looks.
        val power = getSystemService(POWER_SERVICE) as android.os.PowerManager
        if (!power.isInteractive) return
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification())
    }

    /**
     * Establishes the TUN interface with the given parameters and detaches
     * the file descriptor so Dart owns it. Returns the raw fd or null when
     * the interface could not be established.
     */
    fun establish(
        address: String,
        prefixLength: Int,
        routes: List<String>,
        dnsServers: List<String>,
        searchDomains: List<String>,
        mtu: Int,
        proxyHost: String = "",
        proxyPort: Int = 0,
        notificationTitle: String = "",
        disconnectLabel: String = "",
    ): Int? {
        // Without any DNS server the VPN network cannot resolve names (apps
        // get 0.0.0.0), so fall back to the underlying network's resolvers.
        val effectiveDns = dnsServers.ifEmpty { underlyingDnsServers() }
        val builder = Builder()
            .setSession("flutter_sangfor")
            .addAddress(address, prefixLength)
        if (mtu > 0) {
            builder.setMtu(mtu)
        }
        if (proxyHost.isNotEmpty() && proxyPort > 0 &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
        ) {
            // Regular TCP resources are only reachable through the TCP
            // tunnel, not raw L3 forwarding, so apps that honor the system
            // proxy are pointed at the app's loopback proxy instead.
            builder.setHttpProxy(
                android.net.ProxyInfo.buildDirectProxy(proxyHost, proxyPort),
            )
        }
        for (route in routes) {
            val separator = route.lastIndexOf('/')
            if (separator <= 0) continue
            val prefix = route.substring(0, separator)
            val length = route.substring(separator + 1).toIntOrNull() ?: continue
            // Keep the resolvers outside the TUN so DNS queries stay on the
            // underlying network instead of looping through the tunnel.
            if (effectiveDns.any { routeCovers(prefix, length, it) }) continue
            builder.addRoute(prefix, length)
        }
        for (dns in effectiveDns) {
            builder.addDnsServer(dns)
        }
        for (domain in searchDomains) {
            builder.addSearchDomain(domain)
        }
        val descriptor: ParcelFileDescriptor = builder.establish() ?: return null
        if (notificationTitle.isNotEmpty()) {
            this.notificationTitle = notificationTitle
        }
        if (disconnectLabel.isNotEmpty()) {
            this.disconnectLabel = disconnectLabel
        }
        notifyUpdated()
        return descriptor.detachFd()
    }

    /** DNS servers of the current underlying (non-VPN) network. */
    private fun underlyingDnsServers(): List<String> {
        val manager = getSystemService(CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
        val network = manager.activeNetwork ?: return emptyList()
        val properties = manager.getLinkProperties(network) ?: return emptyList()
        return properties.dnsServers.mapNotNull { it.hostAddress }
    }

    private fun routeCovers(prefix: String, length: Int, address: String): Boolean {
        if (length < 0 || length > 32) return false
        val network = parseIpv4(prefix) ?: return false
        val host = parseIpv4(address) ?: return false
        val mask = if (length == 0) 0 else (-1 shl (32 - length))
        return (network and mask) == (host and mask)
    }

    private fun parseIpv4(raw: String): Int? {
        val parts = raw.split('.')
        if (parts.size != 4) return null
        var value = 0
        for (part in parts) {
            val octet = part.toIntOrNull() ?: return null
            if (octet < 0 || octet > 255) return null
            value = (value shl 8) or octet
        }
        return value
    }

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        "VPN",
                        NotificationManager.IMPORTANCE_LOW,
                    )
                )
            }
        }
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        val disconnectIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, VpnTunnelService::class.java).setAction(ACTION_DISCONNECT),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val deletedIntent = PendingIntent.getService(
            this,
            2,
            Intent(this, VpnTunnelService::class.java)
                .setAction(ACTION_NOTIFICATION_DELETED),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return builder
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle(notificationTitle)
            .setContentText(
                "\u2193 ${formatSpeed(speedDown)}   \u2191 ${formatSpeed(speedUp)}",
            )
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setWhen(startedWallClock)
            .setUsesChronometer(true)
            .setDeleteIntent(deletedIntent)
            .addAction(
                Notification.Action.Builder(
                    null,
                    disconnectLabel,
                    disconnectIntent,
                ).build(),
            )
            .build()
    }

    private fun formatSpeed(bytesPerSecond: Long): String {
        if (bytesPerSecond >= 1024L * 1024L) {
            return String.format("%.1f MB/s", bytesPerSecond / (1024.0 * 1024.0))
        }
        if (bytesPerSecond >= 1024L) {
            return "${bytesPerSecond / 1024L} KB/s"
        }
        return "$bytesPerSecond B/s"
    }
}
