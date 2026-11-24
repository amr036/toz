/// Every URL / DAL object id the ZYXEL driver touches lives here, so that if
/// your firmware build names something differently you only edit this file.
///
/// How to verify on your own VMG3625-T50B: open http://192.168.1.1 in Chrome,
/// press F12 → Network → filter "DAL", log in and open the page in question
/// (e.g. Network Setting → Home Networking, Traffic Status, QoS → Shaper).
/// Each request shows up as `/cgi-bin/DAL?oid=<name>`; copy that name here.
class ZyxelEndpoints {
  const ZyxelEndpoints({
    this.rsaPublicKey = '/getRSAPublickKey',
    this.login = '/UserLogin',
    this.logout = '/cgi-bin/UserLogout',
    this.reboot = '/cgi-bin/Reboot',
    this.dalPath = '/cgi-bin/DAL',
    this.statusOids = const ['cardpage_status', 'status'],
    this.trafficOids = const ['Traffic_Status', 'traffic_status', 'cardpage_status', 'status'],
    this.lanHostsOid = 'lanhosts',
    this.wlanOid = 'wlan',
    this.lanDnsOid = 'lan',
    this.qosOid = 'qos',
    this.qosShaperOid = 'qos_shaper',
    this.parentalOid = 'paren_ctl',
    this.shaperInterfaceHints = const ['wl', 'wifi', 'wlan', 'ssid'],
  });

  /// Newer firmwares (V5.50+) encrypt login + DAL payloads: RSA-wrapped
  /// AES-256-CBC. If this endpoint answers with `RSAPublicKey` we switch to
  /// encrypted mode automatically.
  final String rsaPublicKey;
  final String login;
  final String logout;
  final String reboot;
  final String dalPath;

  /// Tried in order; the first that answers ZCFG_SUCCESS wins.
  final List<String> statusOids;
  final List<String> trafficOids;
  final String lanHostsOid;
  final String wlanOid;

  /// LAN setup object that holds the DNS servers handed out by DHCP.
  final String lanDnsOid;
  final String qosOid;
  final String qosShaperOid;

  /// Parental control profiles — used to cut a device's internet access.
  final String parentalOid;

  /// Shaper rows whose interface name contains one of these are treated as
  /// the Wi-Fi/LAN-side (download) shaper. Falls back to the first row.
  final List<String> shaperInterfaceHints;

  String dal(String oid) => '$dalPath?oid=$oid';
}
