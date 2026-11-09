import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let win = UIWindow(frame: UIScreen.main.bounds)
        win.backgroundColor = Theme.background
        win.overrideUserInterfaceStyle = .dark

        if ServerStore.shared.hasCredentials {
            win.rootViewController = MainTabBarController()
        } else {
            let loginVC = LoginViewController()
            loginVC.onAuthenticated = { [weak win] in
                win?.rootViewController = MainTabBarController()
            }
            win.rootViewController = loginVC
        }

        win.makeKeyAndVisible()
        self.window = win
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // App 切回前台：如果主控制器已加载，可智能提示剪贴板加房
        NotificationCenter.default.post(name: .appDidBecomeActiveNotification, object: nil)
    }
}

extension Notification.Name {
    static let appDidBecomeActiveNotification = Notification.Name("appDidBecomeActiveNotification")
}
