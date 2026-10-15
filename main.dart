import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:multicast_dns/multicast_dns.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

void main() => runApp(const MaterialApp(home: HomePage()));

class Printer {
  final String name, host;
  int? ippPort, scanPort;
  String ippPath = 'ipp/print', scanPath = 'eSCL';
  final formats = <String>{}; // printer jo file types leta hai
  Printer(this.name, this.host);
  bool get canPrint => ippPort != null;
  bool get canScan => scanPort != null;
}

// ---------- 1. Discovery (mDNS / Bonjour) ----------
Stream<T> _limit<T>(Stream<T> s) =>
    s.timeout(const Duration(seconds: 4), onTimeout: (sink) => sink.close());

String _clean(String p) => p.replaceAll(RegExp(r'^/+|/+$'), '');

Future<void> _browse(MDnsClient client, String service, String txtKey,
    void Function(String name, String host, int port, String path) onFound) async {
  await for (final ptr in _limit(client.lookup<PtrResourceRecord>(
      ResourceRecordQuery.serverPointer(service)))) {
    final name = ptr.domainName.split('._').first;
    var path = '';

    await for (final txt in _limit(client.lookup<TxtResourceRecord>(
        ResourceRecordQuery.text(ptr.domainName)))) {
      for (final line in txt.text.split('\n')) {
        if (line.startsWith('$txtKey=')) path = _clean(line.substring(txtKey.length + 1));
      }
      break;
    }

    await for (final srv in _limit(client.lookup<SrvResourceRecord>(
        ResourceRecordQuery.service(ptr.domainName)))) {
      await for (final ip in _limit(client.lookup<IPAddressResourceRecord>(
          ResourceRecordQuery.addressIPv4(srv.target)))) {
        onFound(name, ip.address.address, srv.port, path);
        break;
      }
      break;
    }
  }
}

Future<List<Printer>> discover() async {
  final byHost = <String, Printer>{};
  final client = MDnsClient();
  await client.start();
  try {
    await _browse(client, '_ipp._tcp.local', 'rp', (n, h, port, path) {
      final p = byHost.putIfAbsent(h, () => Printer(n, h));
      p.ippPort = port;
      if (path.isNotEmpty) p.ippPath = path;
    });
    await _browse(client, '_uscan._tcp.local', 'rs', (n, h, port, path) {
      final p = byHost.putIfAbsent(h, () => Printer(n, h));
      p.scanPort = port;
      if (path.isNotEmpty) p.scanPath = path;
    });
  } finally {
    client.stop();
  }
  await Future.wait(byHost.values.map((p) async {
    try { if (p.canPrint) await probeIpp(p); } catch (_) {}
    try { await probeScan(p); } catch (_) {}
  }));
  return byHost.values.toList();
}

// ---------- 2. IPP Print-Job ----------
List<int> _u16(int n) => [(n >> 8) & 0xff, n & 0xff];

Uint8List buildPrintJob(String uri, String format, Uint8List doc) {
  final b = BytesBuilder();
  b.add([0x01, 0x01, 0x00, 0x02, 0, 0, 0, 1]); // IPP 1.1, Print-Job, req id 1
  b.addByte(0x01); // operation-attributes group
  void attr(int tag, String name, String value) {
    final n = utf8.encode(name), v = utf8.encode(value);
    b.addByte(tag);
    b.add(_u16(n.length));
    b.add(n);
    b.add(_u16(v.length));
    b.add(v);
  }

  attr(0x47, 'attributes-charset', 'utf-8');
  attr(0x48, 'attributes-natural-language', 'en');
  attr(0x45, 'printer-uri', uri);
  attr(0x42, 'requesting-user-name', 'user');
  attr(0x49, 'document-format', format);
  b.addByte(0x03); // end of attributes
  b.add(doc);
  return b.toBytes();
}

String ippStatusName(int code) => switch (code) {
      0x0400 => 'bad request',
      0x0401 => 'forbidden',
      0x0402 || 0x0403 => 'login/permission chahiye',
      0x0404 => 'not possible',
      0x0406 => 'printer path galat',
      0x0408 => 'file bahut badi hai',
      0x040A => 'file format support nahi',
      0x040B => 'settings support nahi',
      0x0503 => 'IPP version support nahi',
      0x0504 || 0x0505 => 'printer error',
      0x0506 => 'printer job nahi le raha',
      0x0507 => 'printer busy',
      _ => 'unknown',
    };

// null = success, warna error ka text
Future<String?> _sendJob(Printer p, String format, Uint8List bytes) async {
  final path = '${p.ippPort}/${p.ippPath}';
  final res = await http.post(
    Uri.parse('http://${p.host}:$path'),
    headers: {'Content-Type': 'application/ipp'},
    body: buildPrintJob('ipp://${p.host}:$path', format, bytes),
  );
  if (res.statusCode != 200) return 'HTTP ${res.statusCode}';
  if (res.bodyBytes.length < 4) return 'khali jawab';
  final code = (res.bodyBytes[2] << 8) | res.bodyBytes[3];
  if (code < 0x0100) return null; // successful
  return 'IPP 0x${code.toRadixString(16)}: ${ippStatusName(code)}';
}

Future<String?> printFile(Printer p, String ext, Uint8List bytes) async {
  final e = ext.toLowerCase();
  var format = switch (e) {
    'pdf' => 'application/pdf',
    'png' => 'image/png',
    _ => 'image/jpeg',
  };
  var data = bytes;

  if (p.formats.isNotEmpty && !p.formats.contains(format)) {
    if (e != 'pdf' && p.formats.contains('application/pdf')) {
      data = await jpegToPdf(bytes); // photo ko PDF bana ke bhejo
      format = 'application/pdf';
    } else if (p.formats.contains('application/octet-stream')) {
      format = 'application/octet-stream';
    } else {
      return e == 'pdf'
          ? 'ye printer PDF nahi leta, photo (JPG) bhejo'
          : 'ye printer is file type ko nahi leta';
    }
  }

  final first = await _sendJob(p, format, data);
  if (first == null) return null;
  if (p.formats.isEmpty) {
    // printer ne formats nahi bataye: printer ko khud pehchanne do
    final second = await _sendJob(p, 'application/octet-stream', data);
    if (second == null) return null;
  }
  return first;
}

// ---------- IPP probe: printer zinda hai? kaun se formats leta hai? ----------
Uint8List _buildGetAttrs(String uri) {
  final b = BytesBuilder();
  b.add([0x01, 0x01, 0x00, 0x0B, 0, 0, 0, 2]); // IPP 1.1, Get-Printer-Attributes
  b.addByte(0x01);
  void attr(int tag, String name, String value) {
    final n = utf8.encode(name), v = utf8.encode(value);
    b.addByte(tag);
    b.add(_u16(n.length));
    b.add(n);
    b.add(_u16(v.length));
    b.add(v);
  }

  attr(0x47, 'attributes-charset', 'utf-8');
  attr(0x48, 'attributes-natural-language', 'en');
  attr(0x45, 'printer-uri', uri);
  attr(0x44, 'requested-attributes', 'document-format-supported');
  b.addByte(0x03);
  return b.toBytes();
}

Future<bool> probeIpp(Printer p) async {
  final port = p.ippPort;
  if (port == null) return false;
  for (final path in {p.ippPath, 'ipp/print', 'ipp', 'ipp/printer'}) {
    try {
      final res = await http
          .post(Uri.parse('http://${p.host}:$port/$path'),
              headers: {'Content-Type': 'application/ipp'},
              body: _buildGetAttrs('ipp://${p.host}:$port/$path'))
          .timeout(const Duration(seconds: 4));
      if (res.statusCode == 200 && res.bodyBytes.length > 3 && res.bodyBytes[2] == 0) {
        p.ippPath = path;
        final text = latin1.decode(res.bodyBytes, allowInvalid: true);
        for (final f in [
          'application/pdf',
          'image/jpeg',
          'image/png',
          'application/octet-stream'
        ]) {
          if (text.contains(f)) p.formats.add(f);
        }
        return true;
      }
    } catch (_) {}
  }
  return false;
}

// eSCL announce na ho tab bhi port 80 par scanner dhundho
Future<void> probeScan(Printer p) async {
  if (p.canScan) return;
  for (final path in ['eSCL', 'escl']) {
    try {
      final r = await http
          .get(Uri.parse('http://${p.host}/$path/ScannerCapabilities'))
          .timeout(const Duration(seconds: 3));
      if (r.statusCode == 200 && r.body.contains('ScannerCapabilities')) {
        p.scanPort = 80;
        p.scanPath = path;
        return;
      }
    } catch (_) {}
  }
}

// IP se printer add karo
Future<Printer?> addByIp(String ip) async {
  final p = Printer('Printer $ip', ip)..ippPort = 631;
  if (!await probeIpp(p)) p.ippPort = null;
  await probeScan(p);
  return (p.canPrint || p.canScan) ? p : null;
}

// ---------- 3. eSCL Scan ----------
const _scanXml = '''<?xml version="1.0" encoding="UTF-8"?>
<scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
  <pwg:Version>2.1</pwg:Version>
  <pwg:ScanRegions>
    <pwg:ScanRegion>
      <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
      <pwg:Width>2481</pwg:Width>
      <pwg:Height>3507</pwg:Height>
      <pwg:XOffset>0</pwg:XOffset>
      <pwg:YOffset>0</pwg:YOffset>
    </pwg:ScanRegion>
  </pwg:ScanRegions>
  <pwg:InputSource>Platen</pwg:InputSource>
  <scan:ColorMode>RGB24</scan:ColorMode>
  <scan:XResolution>300</scan:XResolution>
  <scan:YResolution>300</scan:YResolution>
  <pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>
</scan:ScanSettings>''';

Future<Uint8List> scanPage(Printer p) async {
  final base = 'http://${p.host}:${p.scanPort}/${p.scanPath}';
  final res = await http.post(
    Uri.parse('$base/ScanJobs'),
    headers: {'Content-Type': 'text/xml'},
    body: _scanXml,
  );
  if (res.statusCode != 201) {
    throw Exception('Scan job reject hui (${res.statusCode})');
  }
  final loc = res.headers['location'];
  if (loc == null) throw Exception('Printer ne job ka address nahi diya');

  var path = Uri.parse(loc).path;
  if (path.endsWith('/')) path = path.substring(0, path.length - 1);
  final docUri = Uri(
      scheme: 'http', host: p.host, port: p.scanPort, path: '$path/NextDocument');

  for (var i = 0; i < 25; i++) {
    final r = await http.get(docUri);
    if (r.statusCode == 200) return r.bodyBytes;
    if (r.statusCode == 503) {
      await Future.delayed(const Duration(milliseconds: 1500)); // scanner busy
      continue;
    }
    throw Exception('Scan nahi hua (${r.statusCode})');
  }
  throw Exception('Timeout: scan nahi aaya');
}

Future<Uint8List> jpegToPdf(Uint8List jpg) async {
  final doc = pw.Document();
  final img = pw.MemoryImage(jpg);
  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat.a4,
    margin: pw.EdgeInsets.zero,
    build: (_) => pw.Center(child: pw.Image(img, fit: pw.BoxFit.contain)),
  ));
  return doc.save();
}

// ---------- 4. UI ----------
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Printer> printers = [];
  Printer? selected;
  Uint8List? scanned;
  bool busy = false;
  String status = 'Printer dhundh raha hai...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => search());
  }

  Future<void> search() async {
    setState(() { busy = true; status = 'Printer dhundh raha hai...'; });
    try {
      final list = await discover();
      final keep = selected == null
          ? null
          : list.where((p) => p.host == selected!.host).firstOrNull;
      setState(() {
        printers = list;
        selected = keep ?? (list.length == 1 ? list.first : null);
        status = list.isEmpty
            ? 'Koi printer nahi mila'
            : (selected == null ? 'Neeche se printer chuno' : 'Taiyaar ✅');
      });
    } catch (e) {
      setState(() => status = 'Error: $e');
    }
    setState(() => busy = false);
  }

  // Selected printer lautata hai, ya picker kholkar null deta hai
  Printer? need(bool Function(Printer) ok, String what) {
    final p = selected;
    if (p == null) {
      setState(() => status = 'Pehle neeche se printer chuno');
      pickPrinter();
      return null;
    }
    if (!ok(p)) {
      setState(() => status = 'Is printer me $what nahi mila');
      return null;
    }
    return p;
  }

  Future<void> doPrint() async {
    final p = need((p) => p.canPrint, 'Print');
    if (p == null) return;
    final pick = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png'],
        withData: true);
    if (pick == null || pick.files.single.bytes == null) return;
    setState(() { busy = true; status = 'Print bhej raha hai...'; });
    try {
      final f = pick.files.single;
      final err = await printFile(p, f.extension ?? 'pdf', f.bytes!);
      setState(() => status = err == null
          ? 'Print bhej diya ✅'
          : 'Printer ne reject kiya ❌ ($err)');
    } catch (e) {
      setState(() => status = 'Error: $e');
    }
    setState(() => busy = false);
  }

  Future<void> doScan() async {
    final p = need((p) => p.canScan, 'Scan');
    if (p == null) return;
    setState(() { busy = true; status = 'Scan ho raha hai... (page glass par rakho)'; });
    try {
      final img = await scanPage(p);
      setState(() { scanned = img; status = 'Scan ho gaya ✅'; });
    } catch (e) {
      setState(() => status = 'Error: $e');
    }
    setState(() => busy = false);
  }

  Future<void> doCopy() async {
    final p = need((p) => p.canScan && p.canPrint, 'Copy (scan + print)');
    if (p == null) return;
    setState(() { busy = true; status = 'Scan ho raha hai... (page glass par rakho)'; });
    try {
      final img = await scanPage(p);
      setState(() { scanned = img; status = 'Print ho raha hai...'; });
      var err = await printFile(p, 'jpg', img);
      if (err != null) err = await printFile(p, 'pdf', await jpegToPdf(img)); // fallback
      setState(() => status = err == null
          ? 'Copy ho gaya ✅'
          : 'Print reject hua ❌ ($err)');
    } catch (e) {
      setState(() => status = 'Error: $e');
    }
    setState(() => busy = false);
  }

  Future<void> savePdf() async {
    final img = scanned;
    if (img == null) return;
    try {
      final pdf = await jpegToPdf(img);
      final path = await FilePicker.platform.saveFile(
          dialogTitle: 'PDF save karo', fileName: 'scan.pdf', bytes: pdf);
      setState(() => status = path == null ? 'Save cancel hua' : 'PDF save ho gayi ✅');
    } catch (e) {
      setState(() => status = 'Error: $e');
    }
  }

  Future<void> addIpDialog() async {
    final c = TextEditingController();
    final ip = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Printer ka IP'),
        content: TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(hintText: '192.168.29.50'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Add')),
        ],
      ),
    );
    if (ip == null || ip.isEmpty || !mounted) return;
    setState(() { busy = true; status = '$ip check ho raha hai...'; });
    final p = await addByIp(ip);
    setState(() {
      busy = false;
      if (p == null) {
        status = '$ip par printer ka jawab nahi aaya (IPP band ho sakta hai)';
      } else {
        printers = [...printers.where((x) => x.host != ip), p];
        selected = p;
        status = 'Add ho gaya ✅';
      }
    });
  }

  void pickPrinter() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              title: const Text('Printer chuno',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              trailing: IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: busy
                    ? null
                    : () async {
                        await search();
                        setSheet(() {});
                      },
              ),
            ),
            if (printers.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Koi printer nahi mila. Refresh dabao.'),
              ),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final p in printers)
                  ListTile(
                    leading: const Icon(Icons.print),
                    title: Text(p.name),
                    subtitle: Text(
                        '${p.host}  •  Print ${p.canPrint ? "✓" : "✗"}  •  Scan ${p.canScan ? "✓" : "✗"}'),
                    selected: selected == p,
                    onTap: () {
                      setState(() { selected = p; status = 'Taiyaar ✅'; });
                      Navigator.pop(ctx);
                    },
                  ),
              ]),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('IP se add karo'),
              onTap: () {
                Navigator.pop(ctx);
                addIpDialog();
              },
            ),
          ]),
        ),
      ),
    );
  }

  Widget tile(IconData icon, String label, VoidCallback? onTap) => Card(
        child: InkWell(
          onTap: onTap,
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 40, color: onTap == null ? Colors.grey : null),
              const SizedBox(height: 8),
              Text(label, style: const TextStyle(fontSize: 16)),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final p = selected;
    return Scaffold(
      appBar: AppBar(title: const Text('Wi-Fi Print & Scan')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(status, textAlign: TextAlign.center),
          ),
          if (busy) const LinearProgressIndicator(),
          const SizedBox(height: 8),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.25,
            children: [
              tile(Icons.print, 'Print', busy ? null : doPrint),
              tile(Icons.document_scanner, 'Scan', busy ? null : doScan),
              tile(Icons.content_copy, 'Copy', busy ? null : doCopy),
              tile(Icons.picture_as_pdf, 'Save PDF',
                  busy || scanned == null ? null : savePdf),
            ],
          ),
          if (scanned != null) ...[
            const SizedBox(height: 12),
            SizedBox(height: 260, child: Image.memory(scanned!)),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Card(
          margin: const EdgeInsets.all(12),
          child: ListTile(
            leading: const Icon(Icons.print_outlined),
            title: Text(p?.name ?? 'Printer chuno'),
            subtitle: Text(p == null
                ? 'Tap karke select karo'
                : '${p.host}  •  Print ${p.canPrint ? "✓" : "✗"}  •  Scan ${p.canScan ? "✓" : "✗"}'),
            trailing: const Icon(Icons.expand_less),
            onTap: pickPrinter,
          ),
        ),
      ),
    );
  }
}
