import 'dart:async';
import 'dart:io'; // Für File-Operationen
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:logging/logging.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:simple_frame_app/text_utils.dart';
import 'package:simple_frame_app/tx/plain_text.dart';
import 'package:simple_frame_app/tx/code.dart'; // Für TxCode hinzugefügt
import 'tap_data_response.dart';

void main() => runApp(const MainApp());

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => MainAppState();
}

class MainAppState extends State<MainApp> with SimpleFrameAppState {
  StreamSubscription<int>? _tapSubs;
  String? _message;
  List<String> _words = []; // Liste für die Wörter
  int _currentWordIndex = 0;
  bool _isPlaying = false;
  double _wpm = 400.0; // Initiale Wörter pro Minute (maximal)
  double _punctuationMultiplier = 1.0; // Initialer Multiplikator für Satzzeichen
  double _shortWordMultiplier = 1.0; // Initialer Multiplikator für kurze Wörter
  Timer? _wordTimer;

  Timer? _keepAliveTimer; // Hinzugefügt
  Timer? _tapEnableTimer; // Hinzugefügt

  ScrollController _scrollController = ScrollController();
  final GlobalKey _footerKey = GlobalKey();

  double get footerButtonsHeight {
    final RenderBox? renderBox =
        _footerKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox != null) {
      return renderBox.size.height;
    } else {
      // Standardhöhe verwenden, wenn die Messung noch nicht verfügbar ist
      return 50.0;
    }
  }

  int _startWordIndex = 0; // Startwort für RSVP

  // Debounce variables
  DateTime _lastTapTime = DateTime.now().subtract(Duration(seconds: 1));
  final Duration _tapDebounceDuration = Duration(milliseconds: 300);

  // Feste Zeilenhöhe definieren
  static const double rowHeight = 30.0;

  // **Neue Zustandsvariable für die Sichtbarkeit der Slider**
  bool _showSliders = false;

  // **GlobalKey für Scaffold**
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  MainAppState() {
    Logger.root.level = Level.FINE; // Set to FINE for more detailed logs
    Logger.root.onRecord.listen((record) {
      debugPrint(
          '${record.level.name}: [${record.loggerName}] ${record.time}: ${record.message}');
    });
  }

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _wordTimer?.cancel();
    _tapSubs?.cancel(); // Hinzugefügt, um Tap-Abonnement zu beenden
    _scrollController.dispose();
    super.dispose();
  }

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
        File file = File(result.files.single.path!); // Verwendung von dart:io

        String content = await file.readAsString();
        _log.info('Dateiinhalt erfolgreich geladen.');

        setState(() {
          // Text in Wörter aufteilen
          _words = _splitTextIntoWords(content);
          _currentWordIndex = _startWordIndex;
        });

        // Scrollen zur aktuellen Zeile nach dem Aufbau des Widgets
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToCurrentWord();
        });

        // Frame abonnieren für Tap-Ereignisse
        if (frame != null) {
          _tapSubs?.cancel();
          _tapSubs = tapDataResponse(
            frame!.dataResponse,
            const Duration(milliseconds: 300),
          ).listen(
            (taps) {
              final now = DateTime.now();
              if (now.difference(_lastTapTime) > _tapDebounceDuration) {
                _lastTapTime = now;
                _message = '$taps-tap detected';
                _log.info(_message!);
                setState(() {
                  if (_isPlaying) {
                    _pauseRSVP();
                  } else {
                    _startRSVP();
                  }
                });
              } else {
                _log.fine('Tap ignored due to debounce');
              }
            },
            onError: (error) {
              _log.warning('Tap subscription error: $error');
            },
            onDone: () {
              _log.warning('Tap subscription closed.');
            },
          );

          // Aktiviert Tap-Event-Abonnement auf dem Frame
          await frame!.sendMessage(TxCode(msgCode: 0x10, value: 1));

          // Prompt the user to begin tapping
          await frame!
              .sendMessage(TxPlainText(msgCode: 0x12, text: 'Tap away!'));
        }
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
    _words.clear();
    _stopRSVP();
    _tapSubs?.cancel(); // Stoppe das Abonnement für Tap-Ereignisse

    // Stoppen Sie die Keep-Alive- und Tap-Enable-Timer
    _stopKeepAlive();
    _stopTapEnableTimer();

    if (frame != null) {
      await frame!.sendMessage(
          TxCode(msgCode: 0x10, value: 0)); // Tap-Abonnement deaktivieren
    }
    if (mounted) setState(() {});
  }

  void _startKeepAlive() {
    _keepAliveTimer = Timer.periodic(Duration(seconds: 30), (timer) async {
      if (frame != null) {
        try {
          await frame!
              .sendMessage(TxCode(msgCode: 0x11, value: 0)); // Keep-Alive-Nachricht
          _log.info('Keep-Alive-Nachricht an Frame gesendet.');
        } catch (e) {
          _log.warning('Fehler beim Senden der Keep-Alive-Nachricht: $e');
        }
      }
    });
  }

  void _stopKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
  }

  void _startTapEnableTimer() {
    _tapEnableTimer = Timer.periodic(Duration(minutes: 1), (timer) async {
      if (frame != null) {
        try {
          await frame!
              .sendMessage(TxCode(msgCode: 0x10, value: 1)); // Tap-Ereignisse aktivieren
          _log.info('Tap-Ereignisse auf Frame reaktiviert.');
        } catch (e) {
          _log.warning('Fehler beim Reaktivieren der Tap-Ereignisse: $e');
        }
      }
    });
  }

  void _stopTapEnableTimer() {
    _tapEnableTimer?.cancel();
    _tapEnableTimer = null;
  }

  List<String> _splitTextIntoWords(String text) {
    // Teilt den Text in Wörter und behält die Punctuation am Ende bei
    // Angepasste RegExp zur besseren Worttrennung inklusive deutscher Sonderzeichen
    RegExp exp = RegExp(r"([A-Za-zÄÖÜäöüß]+(?:['-][A-Za-zÄÖÜäöüß]+)?[.,!?;]?)");
    Iterable<RegExpMatch> matches = exp.allMatches(text);
    return matches.map((m) => m.group(0)!).toList();
  }

  void _startRSVP() {
    if (_isPlaying) return;
    if (_currentWordIndex >= _words.length) {
      _currentWordIndex = _startWordIndex; // Startpunkt festlegen
    }
    _isPlaying = true;
    _log.info('RSVP gestartet bei $_wpm WPM.');
    _scrollToCurrentWord(); // Scroll zur aktuellen Zeile beim Start
    _scheduleNextWord();
  }

  void _pauseRSVP() {
    _isPlaying = false;
    _wordTimer?.cancel();
    _wordTimer = null;
    _log.info('RSVP pausiert.');
  }

  void _stopRSVP() {
    _isPlaying = false;
    _wordTimer?.cancel();
    _wordTimer = null;
    _currentWordIndex = _startWordIndex; // Zurücksetzen auf Startpunkt
    _log.info('RSVP gestoppt.');
    _sendTextToFrame(clear: true);
  }

  void _scheduleNextWord() {
    if (!_isPlaying || _currentWordIndex >= _words.length) {
      _isPlaying = false;
      _log.info('RSVP beendet.');
      return;
    }

    String currentWord = _words[_currentWordIndex];
    _sendTextToFrame(text: currentWord);

    // Bestimme die Verzögerung basierend auf Wortlänge und Punctuation
    double delaySeconds = 60.0 / _wpm; // Sekunden pro Wort basierend auf WPM

    if (currentWord.endsWith('.') ||
        currentWord.endsWith('!') ||
        currentWord.endsWith('?')) {
      delaySeconds *= _punctuationMultiplier; // Satzzeichen multipliziert
    } else if (currentWord.length <= 3) {
      delaySeconds *= _shortWordMultiplier; // Kürzere Wörter multiplizieren
    }

    // Sicherstellen, dass die Verzögerung nicht negativ oder zu klein ist
    delaySeconds = delaySeconds.clamp(0.01, double.infinity);

    _log.fine('Wort: "$currentWord", Verzögerung: $delaySeconds Sekunden');

    _wordTimer = Timer(Duration(milliseconds: (delaySeconds * 1000).toInt()),
        () {
      setState(() {
        _currentWordIndex++;
      });
      _scrollToCurrentWord(); // Automatisches Scrollen zur aktuellen Zeile
      _scheduleNextWord();
    });
  }

  Future<void> _sendTextToFrame({String? text, bool clear = false}) async {
    try {
      if (frame == null) {
        _log.warning('Frame ist nicht verbunden.');
        return;
      }

      String displayText =
          clear ? "" : (text ?? ""); // Zeigt nur das aktuelle Wort oder leert das Display

      // Optional: Zentrieren durch Frame-spezifische Befehle
      // Falls das Frame keine Zentrierungsbefehle unterstützt, können Leerzeichen hinzugefügt werden
      // Hier wird angenommen, dass das Frame eine feste Breite von z.B. 20 Zeichen hat
      if (!clear && displayText.isNotEmpty) {
        int totalWidth = 20; // Beispiel: Gesamtbreite des Displays in Zeichen
        if (displayText.length > totalWidth) {
          displayText = displayText.substring(0, totalWidth);
        } else {
          int padding = (totalWidth - displayText.length) ~/ 2;
          displayText = ' ' * padding + displayText;
        }
      }

      await frame!.sendMessage(TxPlainText(
        msgCode: 0x12,
        text: displayText,
      ));
      _log.info(
          'Nachricht an Frame gesendet: "${clear ? "Leeren Text gesendet" : displayText}"');

      // Optional: Weitere Logik, um den aktuellen Index auf dem Frame darzustellen
      // Dies hängt davon ab, wie das Frame die Informationen darstellt
    } catch (e) {
      _log.warning('Fehler beim Senden der Nachricht an das Frame: $e');
    }
  }

  /// Methode zum automatischen Scrollen zur aktuellen Zeile
  void _scrollToCurrentWord() {
    if (!_scrollController.hasClients) return;

    // Berechne den Offset, zu dem gescrollt werden soll, um das aktuelle Wort an der Oberseite zu halten
    double targetOffset = _currentWordIndex * rowHeight;

    // Stelle sicher, dass der Offset innerhalb der Grenzen des ScrollControllers liegt
    if (targetOffset > _scrollController.position.maxScrollExtent) {
      targetOffset = _scrollController.position.maxScrollExtent;
    } else if (targetOffset < _scrollController.position.minScrollExtent) {
      targetOffset = _scrollController.position.minScrollExtent;
    }

    // Animiert das Scrollen zum Zieloffset
    _scrollController.animateTo(
      targetOffset,
      duration: Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frame Book Reader - RSVP',
      theme: ThemeData.dark(),
      home: Scaffold(
        key: _scaffoldKey, // **GlobalKey dem Scaffold zuweisen**
        appBar: AppBar(
          title: const Text('Frame Book Reader - RSVP'),
          actions: [
            getBatteryWidget(),
          ],
        ),
        drawer: Drawer(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: ListView(
              children: [
                DrawerHeader(
                  child: Text(
                    'Settings',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                // Slider für Wortgeschwindigkeit
                Text(
                  'Word Speed: ${_wpm.toInt()} WPM',
                  style: TextStyle(color: Colors.white),
                ),
                Slider(
                  value: _wpm,
                  min: 100,
                  max: 800,
                  divisions: 20, // Schritte von 50 WPM
                  label: '${_wpm.toInt()} WPM',
                  onChanged: (value) {
                    setState(() {
                      _wpm = value;
                      _log.info('RSVP-Geschwindigkeit geändert auf: $_wpm WPM');
                    });
                  },
                ),
                SizedBox(height: 20),
                // Slider für Satzzeichen-Multiplikator
                Text(
                  'Punctuation Multiplier: ${_punctuationMultiplier.toStringAsFixed(1)}x',
                  style: TextStyle(color: Colors.white),
                ),
                Slider(
                  value: _punctuationMultiplier,
                  min: 0.5, // Anpassung auf 0.5 bis 3.0
                  max: 3.0,
                  divisions: 25, // Schritte von 0.1
                  label: '${_punctuationMultiplier.toStringAsFixed(1)}x',
                  onChanged: (value) {
                    setState(() {
                      _punctuationMultiplier = value;
                      _log.info(
                          'Satzzeichen-Multiplikator geändert auf: $_punctuationMultiplier x');
                    });
                  },
                ),
                SizedBox(height: 20),
                // Slider für kurze Wörter-Multiplikator
                Text(
                  'Short Word Multiplier: ${_shortWordMultiplier.toStringAsFixed(2)}x',
                  style: TextStyle(color: Colors.white),
                ),
                Slider(
                  value: _shortWordMultiplier,
                  min: 0.5, // Anpassung auf 0.5 bis 2.0
                  max: 2.0,
                  divisions: 30, // Schritte von 0.05
                  label: '${_shortWordMultiplier.toStringAsFixed(2)}x',
                  onChanged: (value) {
                    setState(() {
                      _shortWordMultiplier = value;
                      _log.info(
                          'Kurze Wörter-Multiplikator geändert auf: $_shortWordMultiplier x');
                    });
                  },
                ),
              ],
            ),
          ),
        ),
        body: Column(
          children: [
            Expanded(
              flex: 2,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  // Tap-Handling für Play/Pause-Funktion auf dem Android-Gerät
                  setState(() {
                    if (_isPlaying) {
                      _pauseRSVP();
                    } else {
                      _startRSVP();
                    }
                  });
                },
                child: Container(
                  width: double.infinity, // Nimmt die volle Breite ein
                  alignment: Alignment.center, // Zentriert den Inhalt
                  child: Text(
                    _isPlaying && _currentWordIndex < _words.length
                        ? _words[_currentWordIndex]
                        : '',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
            Divider(),
            Expanded(
              flex: 3,
              child: ListView.builder(
                controller: _scrollController,
                itemCount: _words.length,
                itemExtent: rowHeight, // Feste Zeilenhöhe
                itemBuilder: (context, index) {
                  bool isCurrent = index == _currentWordIndex;
                  bool isStart = index == _startWordIndex;
                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        _startWordIndex = index;
                        _currentWordIndex = _startWordIndex;
                        _pauseRSVP(); // Pause vor dem Setzen des Startpunkts
                        _log.info('Startwort gesetzt auf Index: $_startWordIndex');
                        _sendTextToFrame(text: _words[_currentWordIndex]);
                        _scrollToCurrentWord(); // Scrollen zur angeklickten Zeile
                      });
                    },
                    child: Container(
                      padding:
                          EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                      color: isCurrent
                          ? Colors.yellow
                          : isStart
                              ? Colors.green[700]
                              : null,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Zeilennummer
                          Text(
                            '${index + 1}. ',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: isCurrent || isStart
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isCurrent || isStart
                                  ? Colors.black
                                  : Colors.white,
                            ),
                          ),
                          // Wort
                          Expanded(
                            child: Text(
                              _words[index],
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: isCurrent || isStart
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color: isCurrent || isStart
                                    ? Colors.black
                                    : Colors.white,
                              ),
                              textAlign: TextAlign.left, // Links ausrichten
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        floatingActionButton: getFloatingActionButtonWidget(
          const Icon(Icons.file_open),
          const Icon(Icons.close),
        ),
        persistentFooterButtons: [
          Container(
            key: _footerKey, // Fügen Sie das GlobalKey hier hinzu
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ...getFooterButtonsWidget(),
                  IconButton(
                    icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                    onPressed: () {
                      setState(() {
                        if (_isPlaying) {
                          _pauseRSVP();
                        } else {
                          _startRSVP();
                        }
                      });
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
