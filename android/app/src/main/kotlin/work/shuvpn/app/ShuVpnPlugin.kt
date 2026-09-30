package work.shuvpn.app

import android.app.Activity
import android.content.Context
import android.net.VpnService
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * [ShuVpnService] 的 Dart 侧入口。
 *
 * 通道是 `shuvpn/vpn`，**双向**使用：
 *
 * | 方向 | 方法 | 说明 |
 * | :--- | :--- | :--- |
 * | Dart → 原生 | `isPrepared` | 问一次授权状态 |
 * | Dart → 原生 | `requestPermission` | 弹系统授权对话框 |
 * | Dart → 原生 | `start` | 起服务、建 TUN，返回原始 fd |
 * | Dart → 原生 | `stop` | 停服务（关接口、撤通知） |
 * | 原生 → Dart | `disconnectRequested` | 用户点了通知栏上的「断开」 |
 *
 * 为什么访问权限请求要 `ActivityAware`：`VpnService.prepare()` 返回的 Intent
 * 必须由一个前台 Activity 用 `startActivityForResult` 启动，否则系统直接
 * 拒绝（后台启动 Activity 受限）。依赖包里那份也是同一个做法。
 */
class ShuVpnPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware {

    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var applicationContext: Context? = null
    private var pendingPermission: MethodChannel.Result? = null

    /**
     * `waitForService` 是阻塞轮询，而 `vpnStart` 是在平台线程上被调用的 ——
     * 在这里面阻塞会等来 ANR（服务的 `onStartCommand` 也要跑在同一个线程上，
     * 永远等不到）。所以建接口这一步整个丢到单线程池里。
     */
    private val worker = Executors.newSingleThreadExecutor()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        instance = this
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        applicationContext = null
        if (instance === this) instance = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener { requestCode, resultCode, _ ->
            if (requestCode != PERMISSION_REQUEST_CODE) {
                false
            } else {
                val pending = pendingPermission
                pendingPermission = null
                pending?.success(resultCode == Activity.RESULT_OK)
                true
            }
        }
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isPrepared" -> result.success(isPrepared())
            "requestPermission" -> requestPermission(result)
            "start" -> start(call, result)
            "stop" -> {
                context()?.let { ShuVpnService.stop(it) }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** 有授权时 `prepare()` 返回 null；没授权时返回一个要交给系统 UI 的 Intent。 */
    private fun isPrepared(): Boolean {
        val context = activity ?: applicationContext ?: return false
        return try {
            VpnService.prepare(context) == null
        } catch (_: Exception) {
            false
        }
    }

    private fun requestPermission(result: MethodChannel.Result) {
        val current = activity
        if (current == null) {
            result.error(
                "no_activity",
                "VPN 授权需要一个前台页面才能弹出系统对话框。",
                null,
            )
            return
        }
        val intent = VpnService.prepare(current)
        if (intent == null) {
            result.success(true)
            return
        }
        // 上一次请求还挂着就把它回掉，否则那个 Future 永远不会完成。
        pendingPermission?.error("cancelled", "A newer permission request started.", null)
        pendingPermission = result
        current.startActivityForResult(intent, PERMISSION_REQUEST_CODE)
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val context = context()
        if (context == null) {
            result.error("no_context", "插件没有拿到可用上下文。", null)
            return
        }
        val address = call.argument<String>("address")
        if (address.isNullOrEmpty()) {
            result.error("invalid_options", "VPN 接口地址为空。", null)
            return
        }
        val prefixLength = call.argument<Int>("prefixLength") ?: 32
        val mtu = call.argument<Int>("mtu") ?: 0
        val routes = call.argument<List<String>>("routes") ?: emptyList()
        val dnsServers = call.argument<List<String>>("dnsServers") ?: emptyList()
        // 系统代理指向的是本机那个 HTTP 通道。主机默认回环，只有监听地址被
        // 限定在具名网卡上时 Dart 侧才会传一个别的值。
        val httpProxyHost = call.argument<String>("httpProxyHost") ?: "127.0.0.1"
        val httpProxyPort = call.argument<Int>("httpProxyPort") ?: 0
        val notificationTitle = call.argument<String>("notificationTitle") ?: "ShuVPN"
        val disconnectLabel = call.argument<String>("disconnectLabel") ?: "断开"

        worker.execute {
            ShuVpnService.start(context)
            if (!waitForService()) {
                result.error("service_failed", "VPN 服务没有起来。", null)
                return@execute
            }
            val fd = try {
                ShuVpnService.activeService?.establish(
                    address = address,
                    prefixLength = prefixLength,
                    mtu = mtu,
                    routes = routes,
                    tunnelDnsServers = dnsServers,
                    httpProxyHost = httpProxyHost,
                    httpProxyPort = httpProxyPort,
                    notificationTitle = notificationTitle,
                    disconnectLabel = disconnectLabel,
                )
            } catch (error: Exception) {
                result.error("establish_failed", error.toString(), null)
                return@execute
            }
            if (fd == null || fd < 0) {
                result.error("establish_failed", "VpnService.Builder.establish() 没有返回描述符。", null)
            } else {
                result.success(fd)
            }
        }
    }

    private fun waitForService(
        timeoutMillis: Long = 5000,
        pollMillis: Long = 25,
    ): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (System.currentTimeMillis() < deadline) {
            if (ShuVpnService.activeService != null) return true
            Thread.sleep(pollMillis)
        }
        return ShuVpnService.activeService != null
    }

    private fun context(): Context? = activity?.applicationContext ?: applicationContext

    companion object {
        private const val CHANNEL = "shuvpn/vpn"
        private const val PERMISSION_REQUEST_CODE = 0x5348

        @Volatile
        private var instance: ShuVpnPlugin? = null

        /** 由服务在用户点了通知栏的「断开」时调用。 */
        fun requestDisconnect() {
            instance?.channel?.invokeMethod("disconnectRequested", null)
        }
    }
}
