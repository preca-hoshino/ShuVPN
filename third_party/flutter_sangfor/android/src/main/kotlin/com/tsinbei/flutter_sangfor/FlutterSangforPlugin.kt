package com.tsinbei.flutter_sangfor

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** FlutterSangforPlugin */
class FlutterSangforPlugin :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware {
    private lateinit var channel: MethodChannel
    @Volatile
    private var state = "disconnected"
    private var activity: Activity? = null
    private var applicationContext: android.content.Context? = null
    private var pendingPermissionResult: Result? = null
    private val vpnExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "flutter_sangfor")
        channel.setMethodCallHandler(this)
        applicationContext = flutterPluginBinding.applicationContext
        val events = MethodChannel(flutterPluginBinding.binaryMessenger, "flutter_sangfor/service")
        events.setMethodCallHandler { _, result -> result.notImplemented() }
        serviceEventChannel = events
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener { requestCode, resultCode, _ ->
            if (requestCode == VPN_PREPARE_REQUEST_CODE) {
                val result = pendingPermissionResult
                pendingPermissionResult = null
                result?.success(resultCode == Activity.RESULT_OK)
                true
            } else {
                false
            }
        }
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(
        call: MethodCall,
        result: Result,
    ) {
        when (call.method) {
            "getState" -> result.success(state)
            "getCapabilities" -> result.success(
                mapOf(
                    "platform" to "android",
                    "supportsVpn" to true,
                    "supportsTun" to true,
                    "supportsSocks5" to true,
                    "supportedAuthTypes" to emptyList<String>()
                )
            )
            "disconnect" -> {
                state = "disconnected"
                result.success(null)
            }
            "connect" -> result.error(
                "unsupported",
                "The aTrust transport is not implemented on Android yet.",
                null
            )
            "vpnPrepare" -> result.success(VpnService.prepare(activity) == null)
            "vpnRequestPermission" -> {
                val intent = VpnService.prepare(activity)
                if (intent == null) {
                    result.success(true)
                    return
                }
                val currentActivity = activity
                if (currentActivity == null) {
                    result.error("no_activity", "The VPN permission needs a foreground activity.", null)
                    return
                }
                pendingPermissionResult?.error("cancelled", "A newer permission request started.", null)
                pendingPermissionResult = result
                currentActivity.startActivityForResult(intent, VPN_PREPARE_REQUEST_CODE)
            }
            "vpnStart" -> {
                val context = activity?.applicationContext
                    ?: applicationContext
                if (context == null) {
                    result.error("no_activity", "The VPN service needs an attached activity.", null)
                    return
                }
                val address = call.argument<String>("address") ?: "10.0.0.2"
                val prefixLength = call.argument<Int>("prefixLength") ?: 32
                val routes = call.argument<List<String>>("routes") ?: emptyList()
                val dnsServers = call.argument<List<String>>("dnsServers") ?: emptyList()
                val searchDomains = call.argument<List<String>>("searchDomains") ?: emptyList()
                val mtu = call.argument<Int>("mtu") ?: 0
                val proxyHost = call.argument<String>("proxyHost") ?: ""
                val proxyPort = call.argument<Int>("proxyPort") ?: 0
                val notificationTitle = call.argument<String>("notificationTitle") ?: "VPN"
                val disconnectLabel = call.argument<String>("disconnectLabel") ?: "Disconnect"
                // The service reports itself from the main thread, so the
                // blocking wait must run off the platform thread; otherwise
                // the service can never come up (main thread deadlock -> ANR).
                vpnExecutor.execute {
                    VpnTunnelService.start(context)
                    val started = waitForService()
                    if (!started) {
                        result.error("vpn_start_failed", "The VPN service did not start.", null)
                        return@execute
                    }
                    val fd = VpnTunnelService.activeService?.establish(
                        address,
                        prefixLength,
                        routes,
                        dnsServers,
                        searchDomains,
                        mtu,
                        proxyHost,
                        proxyPort,
                        notificationTitle,
                        disconnectLabel,
                    )
                    if (fd == null) {
                        result.error("vpn_establish_failed", "VpnService.Builder.establish() returned null.", null)
                    } else {
                        state = "connected"
                        result.success(fd)
                    }
                }
            }
            "vpnStats" -> {
                val down = (call.argument<Number>("down") ?: 0).toLong()
                val up = (call.argument<Number>("up") ?: 0).toLong()
                VpnTunnelService.activeService?.updateStats(down, up)
                result.success(null)
            }
            "vpnStop" -> {
                val context = activity?.applicationContext ?: applicationContext
                if (context != null) {
                    VpnTunnelService.stop(context)
                }
                state = "disconnected"
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun waitForService(
        timeoutMillis: Long = 5000,
        pollMillis: Long = 25,
    ): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (System.currentTimeMillis() < deadline) {
            if (VpnTunnelService.activeService != null) return true
            Thread.sleep(pollMillis)
        }
        return VpnTunnelService.activeService != null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        serviceEventChannel = null
        channel.setMethodCallHandler(null)
    }

    companion object {
        private const val VPN_PREPARE_REQUEST_CODE = 7201

        @Volatile
        private var serviceEventChannel: MethodChannel? = null
        private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

        /** Invoked by [VpnTunnelService] when the user taps the
         * notification's disconnect action. */
        fun requestDisconnect() {
            mainHandler.post {
                serviceEventChannel?.invokeMethod("disconnectRequested", null)
            }
        }
    }
}
