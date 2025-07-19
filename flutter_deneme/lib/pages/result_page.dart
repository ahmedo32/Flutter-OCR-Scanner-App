import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_ml_kit/google_ml_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:pdf/widgets.dart' as pw;
import '../models/ocr_result.dart';
import '../services/pdf_service.dart';
import '../pages/crop_page.dart';
import '../services/db_helper.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';

/// Data holder for a page's OCR text and metadata
class PageData {
  final String text;
  final String? lectureCode;
  final String? note;
  final List<String>? tags;
  PageData({required this.text, this.lectureCode, this.note, this.tags});
}

/// Result of the "Save Page" dialog: page data + whether to close
class SavePageResult {
  final PageData page;
  final bool close;
  SavePageResult(this.page, this.close);
}

/// Dialog for editing OCR text and metadata, then either adding a page or saving & closing
class SavePageDialog extends StatelessWidget {
  final String initialText;
  const SavePageDialog({super.key, required this.initialText});

  @override
  Widget build(BuildContext context) {
    final textCtrl = TextEditingController(text: initialText);
    final lectureCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    final tagsCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();

    return AlertDialog(
      title: const Text('Save Page'),
      content: Form(
        key: formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: textCtrl,
                maxLines: null,
                decoration: const InputDecoration(labelText: 'OCR Text'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: lectureCtrl,
                decoration: const InputDecoration(labelText: 'Lecture Code'),
                textCapitalization: TextCapitalization.characters,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: noteCtrl,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: tagsCtrl,
                decoration: const InputDecoration(labelText: 'Tags (comma‑separated)'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            if (formKey.currentState!.validate()) {
              final page = PageData(
                text: textCtrl.text.trim(),
                lectureCode: lectureCtrl.text.trim().isEmpty ? null : lectureCtrl.text.trim(),
                note: noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim(),
                tags: tagsCtrl.text.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList(),
              );
              Navigator.pop(context, SavePageResult(page, false));
            }
          },
          child: const Text('Add Page'),
        ),
        ElevatedButton(
          onPressed: () {
            if (formKey.currentState!.validate()) {
              final page = PageData(
                text: textCtrl.text.trim(),
                lectureCode: lectureCtrl.text.trim().isEmpty ? null : lectureCtrl.text.trim(),
                note: noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim(),
                tags: tagsCtrl.text.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList(),
              );
              Navigator.pop(context, SavePageResult(page, true));
            }
          },
          child: const Text('Save & Close'),
        ),
      ],
    );
  }
}

/// Top action bar with image editing, text editing, and document sharing
class ActionBar extends StatelessWidget {
  final VoidCallback onEditImage;
  final VoidCallback onEditText;
  final VoidCallback onShareDocument;

  const ActionBar({
    super.key,
    required this.onEditImage,
    required this.onEditText,
    required this.onShareDocument,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      children: [
        ElevatedButton.icon(
          onPressed: onEditImage,
          icon: const Icon(Icons.crop),
          label: const Text('Edit Image'),
        ),
        ElevatedButton.icon(
          onPressed: onEditText,
          icon: const Icon(Icons.edit),
          label: const Text('Edit Text/Save'),
        ),
        ElevatedButton.icon(
          onPressed: onShareDocument,
          icon: const Icon(Icons.picture_as_pdf),
          label: const Text('Share Document'),
        ),
      ],
    );
  }
}

/// Service to build multi-page PDF documents
class PdfService {
  static Future<File> buildDocument(List<String> pages) async {
    final doc = pw.Document();
    for (var i = 0; i < pages.length; i++) {
      doc.addPage(
        pw.Page(
          build: (_) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Page ${i + 1}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 8),
              pw.Text(pages[i]),
            ],
          ),
        ),
      );
    }
    final bytes = await doc.save();
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/ocr_doc_${DateTime.now().millisecondsSinceEpoch}.pdf');
    await file.writeAsBytes(bytes);
    return file;
  }
}

/// Main OCR result page with multi-page support
class ResultPage extends StatefulWidget {
  const ResultPage({super.key});
  @override
  State<ResultPage> createState() => _ResultPageState();
}

class _ResultPageState extends State<ResultPage> {
  final _picker = ImagePicker();
  File? _image;
  String _ocrText = '';
  bool _loading = true;
  bool _isShowingDialog = false;
  bool _ocrStarted = false;
  final List<String> _pages = [];
  int _ocrFailureCount = 0;
  final int _maxOcrFailures = 3; // max retries before showing error
  double _textScale = 1.0;
  bool _scaleLoaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_scaleLoaded) {
      _scaleLoaded = true;
      SharedPreferences.getInstance().then((prefs) {
        final v = prefs.getDouble('textScaleFactor') ?? 1.0;
        setState(() => _textScale = v);
      });
      final args = ModalRoute.of(context)?.settings.arguments;
      if (!_ocrStarted && args is File) {
        _image = args;
        _ocrStarted = true;
        _performOCR();
      } else if (!_ocrStarted) {
        setState(() { _ocrText = 'No image provided'; _loading = false; });
        _ocrStarted = true;
      }
    }
  }

Future<void> _cropImage() async {
  final File? cropped = await Navigator.push<File?>(
    context,
    MaterialPageRoute(builder: (_) => CropPage(image: _image!)),
  );
  if (cropped != null) {
    setState(() {
      _image = cropped;
      _loading = true;
    });
    await _performOCR();
  }
}

  Future<void> _performOCR() async {
  if (_image == null) return;
  setState(() { _loading = true; });

  try {
    final input = InputImage.fromFile(_image!);
    final rec   = GoogleMlKit.vision.textRecognizer();
    final res   = await rec.processImage(input);
    await rec.close();

    final raw = res.text.trim();
    if (raw.isEmpty) {
      // No text at all → show dialog & bail out
      setState(() {
        _ocrText = '';
        _loading = false;
      });
      await _showNoTextDetectedDialog();  
      return;
    }

    // Otherwise we have some text
    setState(() {
      _ocrText  = raw;
      _loading  = false;
    });
    _ocrFailureCount = 0;
    await _showSavePageDialog();
  } catch (e) {
    _ocrFailureCount++;
    setState(() {
      _ocrText = 'OCR failed (attempt $_ocrFailureCount of $_maxOcrFailures)';
      _loading = false;
    });
    
    if (_ocrFailureCount < _maxOcrFailures) {
      _showRetryDialog();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Maximum OCR attempts reached. Please try with a different image.'))
        );
      }
      _ocrFailureCount = 0; // Reset for next image
    }
  }
}


  Future<void> _showSavePageDialog() async {
  // Show the dialog and wait for the user's choice
  final result = await showDialog<SavePageResult>(
    context: context,
    builder: (_) => SavePageDialog(initialText: _ocrText),
  );
  if (result == null) return;  // user cancelled

  if (result.close) {
    // ── SAVE & CLOSE ───────────────────────────────────
    final now = DateFormat('yyyy-MM-dd – kk:mm').format(DateTime.now());

    // 1) Persist any pages already buffered
    for (var pageText in _pages) {
      await DBHelper.insertResult(OCRResult(
        imagePath:   _image!.path,
        text:        pageText,
        timestamp:   now,
        lectureCode: result.page.lectureCode,
        note:        result.page.note,
        tags:        result.page.tags,
      ));
    }

    // 2) Persist the very last page they just edited
    await DBHelper.insertResult(OCRResult(
      imagePath:   _image!.path,
      text:        result.page.text,
      timestamp:   now,
      lectureCode: result.page.lectureCode,
      note:        result.page.note,
      tags:        result.page.tags,
    ));

    // 3) Clear buffer for next document
    _pages.clear();

    // 4) Exit the OCR flow
    Navigator.pop(context);
  } else {
    // ── ADD PAGE & CONTINUE ────────────────────────────
    // 1) Buffer this page's text
    setState(() => _pages.add(result.page.text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Page added (total: ${_pages.length})')),
    );

    // 2) Immediately re-open the camera for the next page
    final XFile? next = await _picker.pickImage(source: ImageSource.camera);
    if (!mounted) return;   // guard in case the widget was popped
    if (next == null) return; // user cancelled the camera

    // 3) Run OCR on the new image
    setState(() {
      _image = File(next.path);
      _loading = true;
    });
    await _performOCR();
  }
}





  Future<void> _shareDocument() async {
    if (_pages.isEmpty) {
      ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('No pages to share.')));
      return;
    }

    setState(() => _loading = true);
    try {
      // 1) Build according to user prefs (PDF, TXT, or both)
      final exportedPdf = await PdfService.buildDocument(_pages);

      // 2) Load save‐location preference
      final prefs = await SharedPreferences.getInstance();
      final loc = SaveLocation.values[prefs.getInt('saveLocation') ?? 0];
      final dir = (loc == SaveLocation.documents)
        ? await getApplicationDocumentsDirectory()
        : await getTemporaryDirectory();

      // 3) Derive base name (without extension)
      final filename = exportedPdf.path.split(Platform.pathSeparator).last;
      final baseName = filename.split('.').first;

      // 4) Collect all matching files (*.pdf and/or *.txt)
      final filesToShare = Directory(dir.path)
        .listSync()
        .where((f) {
          final name = f.path.split(Platform.pathSeparator).last;
          return name.startsWith(baseName) &&
                 (name.endsWith('.pdf') || name.endsWith('.txt'));
        })
        .map((f) => XFile(f.path))
        .toList();

      // 5) Share them
      await Share.shareXFiles(filesToShare, text: 'OCR Document');

      // 6) Clear pages buffer
      setState(() => _pages.clear());
    } catch (e) {
      ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Share failed: $e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  void _showRetryDialog() {
    if (_isShowingDialog) return;
    _isShowingDialog = true;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('OCR Failed'),
        content: const Text('Retry OCR?'),
        actions: [
          TextButton(
            onPressed: () { Navigator.pop(context); _isShowingDialog = false; },
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () { Navigator.pop(context); _isShowingDialog = false; _performOCR(); },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Future<void> _showNoTextDetectedDialog() async {
    if (_isShowingDialog) return;
    _isShowingDialog = true;
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('No Text Detected'),
        content: const Text('No text was detected in the image. Would you like to try again?'),
        actions: [
          TextButton(
            onPressed: () { Navigator.pop(context); _isShowingDialog = false; },
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async { 
              Navigator.pop(context); 
              _isShowingDialog = false; 
              
              // Open camera to capture a new image
              final XFile? newImage = await _picker.pickImage(source: ImageSource.camera);
              if (newImage != null && mounted) {
                setState(() {
                  _image = File(newImage.path);
                  _loading = true;
                });
                await _performOCR();
              }
            },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('OCR Result')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_image != null) Image.file(_image!),
                const SizedBox(height: 12),
                ActionBar(
                  onEditImage: _cropImage,
                  onEditText: _showSavePageDialog,
                  onShareDocument: _shareDocument,
                ),
                const Divider(),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(
                      _ocrText,
                      textScaler: TextScaler.linear(_textScale),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
