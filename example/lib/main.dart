import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf_watermark/flutter.dart';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) =>
      const MaterialApp(home: Home(), debugShowCheckedModeBanner: false);
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  String _status = 'Pick a PDF.';

  Future<void> _pickAndStamp() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (picked == null) return;

    setState(() => _status = 'Working…');
    try {
      final input = File(picked.path!);
      final bytes = await input.readAsBytes();
      // TODO: Use your own font
      // final fonts = await File('font_path').readAsBytes();
      final fonts = await File(
              '/home/yujin/Documents/projects/Flutter/pdf_watermark/example/lib/PixelOperator.ttf')
          .readAsBytes();

      final size = readFirstPageSize(bytes);

      final raster = await renderTiledWatermark(
        text: 'ASDFGHJKL12345678 - ${DateTime.now()}',
        pageWidth: size.width,
        pageHeight: size.height,
        fontSize: 8,
        opacity: 0.12,
        color: const Color(0xFF808080),
        gapX: 1,
        gapY: 1,
        fontBytes: fonts // Own Font
      );

      final stamped = watermarkPdf(bytes, raster: raster);

      final dir = await getApplicationDocumentsDirectory();
      final out = File('${dir.path}/watermarked_${DateTime.now()}_${picked.name}');
      await out.writeAsBytes(stamped);
      setState(() => _status = 'Wrote ${out.path}');
    } catch (e) {
      setState(() => _status = 'Failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_status, textAlign: TextAlign.center),
              ),
              FilledButton(
                onPressed: _pickAndStamp,
                child: const Text('Pick PDF and watermark'),
              ),
            ],
          ),
        ),
      );
}
