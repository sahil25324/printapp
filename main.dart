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
  return byHost.values.toList();
}

// ---------- 2. IPP Print-Job ----------
List<int> _u16(int n) => [(n >> 8) & 0xff, n & 0xff];

Uint8List buildPrintJob(String uri, String format, Uint8List doc) {
  final b = BytesBuilder();
  b.add([0x02, 0x00, 0x00, 0x02, 0, 0, 0, 1]); // IPP 2.0, Print-Job, req id 1
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

Future<bool> printFile(Printer p, String ext, Uint8List bytes) async {
  final format = switch (ext.toLowerCase()) {
    'pdf' => 'application/pdf',
    'png' => 'image/png',
    _ => 'image/jpeg',
  };
  final path = '${p.ippPort}/${p.ippPath}';
  final body = buildPrintJob('ipp://${p.host}:$path', format, bytes);
  final res = await http.post(
    Uri.parse('http://${p.host}:$path'),
    headers: {'Content-Type': 'application/ipp'},
    body: body,
  );
  // IPP status code is in bytes 2-3; 0x0000 = successful-ok
  return res.statusCode == 200 && res.bodyBytes.length > 3 && res.bodyBytes[2] == 0;
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
  String status = 'Printer search karo';

  Future<void> search() async {
    setState(() { busy = true; status = 'Dhundh raha hai...'; });
    try {
      final list = await discover();
      setState(() {
        printers = list;
        selected = null;
        status = list.isEmpty ? 'Koi printer nahi mila' : '${list.length} printer mile';
      });
    } catch (e) {
      setState(() => status = 'Error: $e');
    }
    setState(() => busy = false);
  }

  Future<void> doPrint() async {
    final p = selected;
    if (p == null) return;
    final pick = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png'], withData: true);
    if (pick == null || pick.files.single.bytes == null) return;
    setState(() { busy = true; status = 'Print bhej raha hai...'; });
    try {
      final f = pick.files.single;
      final ok = await printFile(p, f.extension ?? 'pdf', f.bytes!);
      setState(() => status = ok ? 'Print bhej diya ✅' : 'Printer ne reject kiya ❌');
    } catch (e) {
      setState(() => status = 'Error: $e');
    }
    setState(() => busy = false);
  }

  Future<void> doScan() async {
    final p = selected;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Wi-Fi Print & Scan')),
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(12), child: Text(status)),
        Expanded(
          child: ListView(
            children: [
              for (final p in printers)
                ListTile(
                  title: Text(p.name),
                  subtitle: Text(
                      '${p.host}  •  Print ${p.canPrint ? "✓" : "✗"}  •  Scan ${p.canScan ? "✓" : "✗"}'),
                  selected: selected == p,
                  onTap: () => setState(() => selected = p),
                ),
            ],
          ),
        ),
        if (scanned != null)
          SizedBox(height: 220, child: Image.memory(scanned!)),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            Row(children: [
              Expanded(child: ElevatedButton(onPressed: busy ? null : search, child: const Text('Search'))),
              const SizedBox(width: 8),
              Expanded(
                  child: ElevatedButton(
                      onPressed: busy || !(selected?.canPrint ?? false) ? null : doPrint,
                      child: const Text('Print'))),
              const SizedBox(width: 8),
              Expanded(
                  child: ElevatedButton(
                      onPressed: busy || !(selected?.canScan ?? false) ? null : doScan,
                      child: const Text('Scan'))),
            ]),
            if (scanned != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(onPressed: savePdf, child: const Text('Save as PDF'))),
              ),
          ]),
        ),
      ]),
    );
  }
}
