import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:multicast_dns/multicast_dns.dart';

void main() => runApp(const MaterialApp(home: HomePage()));

class Printer {
  final String name, host, path;
  final int port;
  Printer(this.name, this.host, this.port, this.path);
}

// ---------- 1. Discovery (mDNS / Bonjour) ----------
Stream<T> _limit<T>(Stream<T> s) =>
    s.timeout(const Duration(seconds: 4), onTimeout: (sink) => sink.close());

Future<List<Printer>> discoverPrinters() async {
  final found = <String, Printer>{};
  final client = MDnsClient();
  await client.start();
  try {
    await for (final ptr in _limit(client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer('_ipp._tcp.local')))) {
      final name = ptr.domainName.split('._ipp').first;
      var path = 'ipp/print';

      await for (final txt in _limit(client.lookup<TxtResourceRecord>(
          ResourceRecordQuery.text(ptr.domainName)))) {
        for (final line in txt.text.split('\n')) {
          if (line.startsWith('rp=')) path = line.substring(3);
        }
        break;
      }

      await for (final srv in _limit(client.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(ptr.domainName)))) {
        await for (final ip in _limit(client.lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv4(srv.target)))) {
          found[name] = Printer(name, ip.address.address, srv.port, path);
          break;
        }
        break;
      }
    }
  } finally {
    client.stop();
  }
  return found.values.toList();
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
  final body = buildPrintJob('ipp://${p.host}:${p.port}/${p.path}', format, bytes);
  final res = await http.post(
    Uri.parse('http://${p.host}:${p.port}/${p.path}'),
    headers: {'Content-Type': 'application/ipp'},
    body: body,
  );
  // IPP status code is in bytes 2-3; 0x0000 = successful-ok
  return res.statusCode == 200 && res.bodyBytes.length > 3 && res.bodyBytes[2] == 0;
}

// ---------- 3. UI ----------
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Printer> printers = [];
  Printer? selected;
  bool busy = false;
  String status = 'Printer search karo';

  Future<void> search() async {
    setState(() { busy = true; status = 'Dhundh raha hai...'; });
    final list = await discoverPrinters();
    setState(() {
      printers = list;
      busy = false;
      status = list.isEmpty ? 'Koi printer nahi mila' : '${list.length} printer mile';
    });
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
                  subtitle: Text('${p.host}:${p.port}'),
                  selected: selected == p,
                  onTap: () => setState(() => selected = p),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(child: ElevatedButton(onPressed: busy ? null : search, child: const Text('Search'))),
            const SizedBox(width: 8),
            Expanded(child: ElevatedButton(onPressed: busy || selected == null ? null : doPrint, child: const Text('Print'))),
          ]),
        ),
      ]),
    );
  }
}
