import UIKit

final class MainTabBarController: UITabBarController {

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        setupTabBar()
        setupViewControllers()
    }

    private func setupTabBar() {
        tabBar.barTintColor = Theme.cardBackground
        tabBar.backgroundColor = Theme.cardBackground
        tabBar.tintColor = Theme.listeningGreen
        tabBar.unselectedItemTintColor = Theme.textMuted
        tabBar.isTranslucent = false

        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = Theme.cardBackground
        tabBar.standardAppearance = appearance
        if #available(iOS 15.0, *) {
            tabBar.scrollEdgeAppearance = appearance
        }
    }

    private func setupViewControllers() {
        // Tab 1: 监控房间
        let roomsVC = RoomsViewController()
        let navRooms = UINavigationController(rootViewController: roomsVC)
        navRooms.tabBarItem = UITabBarItem(
            title: "监控",
            image: UIImage(systemName: "play.tv"),
            selectedImage: UIImage(systemName: "play.tv.fill")
        )
        styleNavigation(navRooms)

        // Tab 2: 运行总览
        let overviewVC = OverviewViewController()
        let navOverview = UINavigationController(rootViewController: overviewVC)
        navOverview.tabBarItem = UITabBarItem(
            title: "总览",
            image: UIImage(systemName: "chart.bar.xaxis"),
            selectedImage: UIImage(systemName: "chart.bar.xaxis")
        )
        styleNavigation(navOverview)

        // Tab 3: 更多与控制台
        let moreVC = MoreViewController()
        let navMore = UINavigationController(rootViewController: moreVC)
        navMore.tabBarItem = UITabBarItem(
            title: "设置",
            image: UIImage(systemName: "gearshape"),
            selectedImage: UIImage(systemName: "gearshape.fill")
        )
        styleNavigation(navMore)

        viewControllers = [navRooms, navOverview, navMore]
    }

    private func styleNavigation(_ nav: UINavigationController) {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = Theme.cardBackground
        appearance.titleTextAttributes = [.foregroundColor: Theme.textPrimary]
        nav.navigationBar.standardAppearance = appearance
        nav.navigationBar.scrollEdgeAppearance = appearance
        nav.navigationBar.tintColor = Theme.textPrimary
    }
}
