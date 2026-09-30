package work.shuvpn.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    /**
     * 注册 [ShuVpnPlugin]。
     *
     * `GeneratedPluginRegistrant` 只会注册 pub 依赖里的插件，本项目自己的
     * 这个必须手工挂上去，否则 `shuvpn/vpn` 通道在 Dart 侧调过去只会拿到
     * `MissingPluginException`。
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(ShuVpnPlugin())
    }
}

