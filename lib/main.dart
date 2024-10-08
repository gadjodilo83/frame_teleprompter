import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:logging/logging.dart';

import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:simple_frame_app/text_utils.dart';
import 'package:simple_frame_app/tx/text.dart';

void main() => runApp(const MainApp());

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => MainAppState();
}

class MainAppState extends State<MainApp> with SimpleFrameAppState {
  MainAppState() {
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((record) {
      debugPrint(
          '${record.level.name}: [${record.loggerName}] ${record.time}: ${record.message}');
    });
  }

  final List<String> _wrappedChunks = []; // Liste für umgebrochene Zeilen
  List<String> _visibleLines = [];
  int _currentLine = 0;
  bool _isTyping = false;
  double _typewriterSpeed = 0.03; // Sekunden pro Buchstabe
  int _currentCharIndex = 0;
  final int _maxLinesOnScreen = 4; // Maximal 4 Zeilen auf dem Bildschirm
  final int _chunkSize = 32; // Maximale Zeichenanzahl pro Zeile

  int _startLine = 0; // Startzeile für den Typewriter-Effekt

  @override
  Future<void> run() async {
    currentState = ApplicationState.running;
    if (mounted) setState(() {});

    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt'],
      );

      if (result != null) {
        File file = File(result.files.single.path!);

        String content = await file.readAsString();
        _log.info('Dateiinhalt erfolgreich geladen.');

        _wrappedChunks.clear();
        setState(() {
          // Ersetze Zeilenumbrüche durch Leerzeichen, um den gesamten Text als einen Absatz zu behandeln
          String singleParagraph = content.replaceAll('\n', ' ');
          _wrappedChunks.addAll(_wrapTextToFit(singleParagraph, _chunkSize));
          _currentLine = 0;
          _currentCharIndex = 0;
          _visibleLines.clear();
        });

      } else {
        currentState = ApplicationState.ready;
        if (mounted) setState(() {});
      }
    } catch (e) {
      _log.fine('Fehler bei der Ausführung der Anwendungslogik: $e');
      currentState = ApplicationState.ready;
      if (mounted) setState(() {});
    }
  }

  @override
  Future<void> cancel() async {
    currentState = ApplicationState.ready;
    _wrappedChunks.clear();
    _visibleLines.clear();
    _stopTypewriterEffect();
    if (mounted) setState(() {});
  }

  void _startTypewriterEffect() {
    if (_isTyping) return; // Verhindere mehrfaches Starten
    _isTyping = true;
    _log.info('Typewriter-Effekt gestartet.');
    _currentLine = _startLine; // Setze die Startzeile für den Typewriter-Effekt
    _currentCharIndex = 0; // Setze den Zeichenindex zurück, um von Anfang der neuen Startzeile zu beginnen
    _visibleLines.clear(); // Setze sichtbare Zeilen zurück, damit der neue Text wieder bei der obersten Zeile beginnt
    _sendTextToFrame(clear: true); // Lösche den bestehenden Text auf dem Frame
    _runTypewriterEffect();
  }

  void _stopTypewriterEffect() {
    _isTyping = false;
    _log.info('Typewriter-Effekt gestoppt.');
    _sendTextToFrame(clear: true); // Lösche den bestehenden Text auf dem Frame
  }

  Future<void> _runTypewriterEffect() async {
    while (_isTyping && _currentLine < _wrappedChunks.length) {
      String wrappedLine = _wrappedChunks[_currentLine];
      _log.info('Verarbeite Zeile $_currentLine: "$wrappedLine"');

      for (; _currentCharIndex < wrappedLine.length; _currentCharIndex += 2) {
        if (!_isTyping) break;

        String charsToAdd = wrappedLine.substring(
            _currentCharIndex,
            (_currentCharIndex + 2 <= wrappedLine.length)
                ? _currentCharIndex + 2
                : wrappedLine.length);

        _addCharacterToVisibleText(charsToAdd);

        await _sendTextToFrame();

        await Future.delayed(Duration(milliseconds: (_typewriterSpeed * 1000).toInt()));
      }

      if (!_isTyping) break;

      _currentCharIndex = 0;
      _currentLine++;

      if (_visibleLines.length > _maxLinesOnScreen) {
        _visibleLines.removeAt(0);
        _log.info('Entferne oberste Zeile, um zu scrollen.');
      }

      setState(() {});

      await Future.delayed(Duration(milliseconds: 100));
    }

    _isTyping = false;
    _log.info('Typewriter-Effekt abgeschlossen.');
  }

  List<String> _wrapTextToFit(String text, int maxCharsPerLine) {
    List<String> lines = [];
    List<String> words = text.split(RegExp(r'\s+')); // Splitte anhand von Leerzeichen
    String currentLine = '';

    for (String word in words) {
      word = word.trim();

      if (word.isEmpty) continue;

      int prospectiveLength = currentLine.isEmpty ? word.length : currentLine.length + 1 + word.length;

      if (prospectiveLength <= maxCharsPerLine) {
        currentLine += (currentLine.isEmpty ? '' : ' ') + word;
      } else {
        if (currentLine.isNotEmpty) {
          lines.add(currentLine);
        }

        if (word.length > maxCharsPerLine) {
          int start = 0;
          while (start < word.length) {
            int end = (start + maxCharsPerLine) < word.length ? start + maxCharsPerLine : word.length;
            lines.add(word.substring(start, end));
            start += maxCharsPerLine;
          }
          currentLine = '';
        } else {
          currentLine = word;
        }
      }
    }

    if (currentLine.isNotEmpty) {
      lines.add(currentLine);
    }

    return lines;
  }

  Future<void> _sendTextToFrame({bool clear = false}) async {
    try {
      if (frame == null) {
        _log.warning('Frame ist nicht verbunden.');
        return;
      }

      String fullText = clear ? "" : _visibleLines.join('\n');

      await frame!.sendMessage(TxPlainText(
        msgCode: 0x0a,
        text: fullText,
      ));
      _log.info('Nachricht an Frame gesendet: "${clear ? "Leeren Text gesendet" : fullText}"');
    } catch (e) {
      _log.warning('Fehler beim Senden der Nachricht an das Frame: $e');
    }
  }

  void _addCharacterToVisibleText(String char) {
    if (_currentCharIndex == 0) {
      _visibleLines.add(char);
    } else {
      _visibleLines[_visibleLines.length - 1] += char;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frame Book reader',
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Frame Book reader'),
          actions: [getBatteryWidget()],
        ),
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragEnd: (x) async {
            // Scroll-Handling
          },
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(),
                Expanded(
                  child: ListView.builder(
                    itemCount: _wrappedChunks.length,
                    itemBuilder: (context, index) {
                      return ListTile(
                        title: Text(
                          _wrappedChunks[index],
                          style: const TextStyle(
                            fontSize: 16,
                            fontFamily: 'Courier',
                          ),
                        ),
                        onTap: () {
                          setState(() {
                            _startLine = index;
                            _currentLine = _startLine; // Setze aktuelle Zeile auf die neue Startzeile
                            _currentCharIndex = 0; // Setze den Zeichenindex zurück
                            _visibleLines.clear(); // Lösche die sichtbaren Zeilen, damit der neue Startpunkt bei der obersten Zeile beginnt
                            _sendTextToFrame(clear: true); // Lösche den bestehenden Text auf dem Frame
                            _log.info('Startzeile geändert auf: $_startLine');
                          });
                        },
                      );
                    },
                  ),
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
        floatingActionButton: getFloatingActionButtonWidget(
            const Icon(Icons.file_open), const Icon(Icons.close)),
        persistentFooterButtons: [
          ...getFooterButtonsWidget(),
          IconButton(
            icon: Icon(_isTyping ? Icons.pause : Icons.play_arrow),
            onPressed: () {
              if (_isTyping) {
                _stopTypewriterEffect();
              } else {
                _startTypewriterEffect();
              }
              if (mounted) setState(() {});
            },
          ),
          SizedBox(
            width: 200,
            child: Slider(
              value: _typewriterSpeed,
              min: 0.03,
              max: 0.2,
              divisions: 17,
              label: '${_typewriterSpeed.toStringAsFixed(2)} s/Buchstabe',
              onChanged: (value) {
                setState(() {
                  _typewriterSpeed = value;
                  _log.info('Typewriter-Geschwindigkeit geändert auf: $value s/Buchstabe');
                });
              },
            ),
          ),
        ],
      ),
    );
  }
}
