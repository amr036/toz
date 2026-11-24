import 'mock/mock_router_driver.dart';
import 'router_driver.dart';
import 'zyxel/zyxel_vmg3625_driver.dart';

/// Router models offered in the setup screen.
///
/// To add a router: implement [RouterDriver], then add an entry here with
/// `available: true` and a factory.
enum RouterModelId { zyxelVmg3625T50b, zteH188a, huaweiHg633, huaweiDn8245 }

class RouterModelInfo {
  const RouterModelInfo({
    required this.id,
    required this.displayName,
    required this.defaultIp,
    required this.defaultUsername,
    this.available = false,
  });

  final RouterModelId id;
  final String displayName;
  final String defaultIp;
  final String defaultUsername;
  final bool available;
}

const routerModels = <RouterModelInfo>[
  RouterModelInfo(
    id: RouterModelId.zyxelVmg3625T50b,
    displayName: 'ZYXEL VMG3625-T50B',
    defaultIp: '192.168.1.1',
    defaultUsername: 'admin',
    available: true,
  ),
  RouterModelInfo(id: RouterModelId.zteH188a, displayName: 'ZTE H168N / H188A', defaultIp: '192.168.1.1', defaultUsername: 'admin'),
  RouterModelInfo(id: RouterModelId.huaweiHg633, displayName: 'Huawei HG630 V2 / HG633', defaultIp: '192.168.1.1', defaultUsername: 'admin'),
  RouterModelInfo(id: RouterModelId.huaweiDn8245, displayName: 'Huawei DN8245', defaultIp: '192.168.1.1', defaultUsername: 'admin'),
];

RouterModelInfo modelInfo(RouterModelId id) => routerModels.firstWhere((m) => m.id == id);

RouterDriver createDriver({
  required RouterModelId model,
  required RouterCredentials credentials,
  required bool demoMode,
}) {
  if (demoMode) return MockRouterDriver(credentials);
  switch (model) {
    case RouterModelId.zyxelVmg3625T50b:
      return ZyxelVmg3625Driver(credentials);
    case RouterModelId.zteH188a:
    case RouterModelId.huaweiHg633:
    case RouterModelId.huaweiDn8245:
      throw const RouterException(RouterErrorCode.notSupported, 'Driver not implemented yet');
  }
}
