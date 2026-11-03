import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'csv_save_stub.dart'
    if (dart.library.js_interop) 'csv_save_web.dart'
    as csv_save;

import 'history_storage_stub.dart'
    if (dart.library.js_interop) 'history_storage_web.dart'
    as history_storage;

// ============================================================
// BLE UUID
// ============================================================

const String serviceId = '8b7c0100-7f30-4a9b-9f57-902a57db1000';

const String ecgId = '8b7c0101-7f30-4a9b-9f57-902a57db1000';

// ============================================================
// ECG CONFIGURATION
// ============================================================

const int sampleRate = 200;

// แสดง ECG 5 วินาที
const int graphSeconds = 5;

const int maxTraceSamples = sampleRate * graphSeconds;

// ============================================================
// RECORDING
// ============================================================

const Duration sessionLength = Duration(minutes: 5);

// ============================================================
// MAIN
// ============================================================

void main() {
  runApp(const TEST());
}

// ============================================================
// APP
// ============================================================

class TEST extends StatelessWidget {
  const TEST({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,

      title: 'ECG Monitor',

      theme: ThemeData(
        useMaterial3: true,

        colorSchemeSeed: const Color(0xff1662d7),

        scaffoldBackgroundColor: const Color(0xffeff6ff),
      ),

      home: const MyApp(),
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const ECGApp();
  }
}

// ============================================================

// ECG PAGE

// ============================================================

class ECGApp extends StatefulWidget {
  const ECGApp({super.key});

  @override
  State<ECGApp> createState() => _ECGAppState();
}

// ============================================================

// STATE

// ============================================================

class _ECGAppState extends State<ECGApp> {
  // ==========================================================

  // BLUETOOTH

  // ==========================================================

  BluetoothDevice? _device;

  // ignore: unused_field
  BluetoothCharacteristic? _characteristic;

  StreamSubscription<List<int>>? _ecgSub;

  StreamSubscription<BluetoothConnectionState>? _connectionSub;

  StreamSubscription<List<ScanResult>>? _scanSub;

  // ==========================================================

  // UI TIMER

  // ==========================================================

  Timer? _uiTimer;

  // ==========================================================

  // FILE

  // ==========================================================

  IOSink? _sink;

  StringBuffer? _webCsv;

  final Map<String, String> _webFiles = {};

  // ==========================================================

  // ECG BUFFER

  // ==========================================================

  final List<int> _trace = [];

  // ==========================================================
  // RAW ECG DATA
  final List<int> _rawEcgSamples = [];
  // RR DATA

  // ==========================================================

  final List<int> _rrIntervals = [];
  final List<Map<String, dynamic>> _rrRecords = [];

  // ==========================================================

  // HISTORY

  // ==========================================================

  final List<Map<String, dynamic>> _history = [];

  // ==========================================================

  // SESSION

  // ==========================================================

  DateTime? _started;

  String? _filePath;

  // ==========================================================

  // STATUS

  // ==========================================================

  String _status = 'ยังไม่เชื่อมต่อ';

  bool _connected = false;

  bool _recording = false;

  bool _scanning = false;

  bool _busy = false;

  bool _connecting = false;

  // ==========================================================

  // COUNTERS

  // ==========================================================

  int _sampleIndex = 0;

  int _sessionSamples = 0;

  int _packetCount = 0;

  // // ==========================================================

  // // R-PEAK

  // // ==========================================================

  // int? _lastPeakSample;

  // int? _lastRR;

  // // previous ECG samples

  // int _previous2 = 2048;

  // int _previous1 = 2048;

  // // adaptive baseline

  // double _baseline = 2048.0;

  // // adaptive amplitude envelope

  // double _envelope = 50.0;

  // ==========================================================

  // R-PEAK DETECTION

  // ==========================================================

  // R-Peak ล่าสุด

  int? _lastPeakSample;

  // RR ล่าสุด (ms)

  int? _lastRR;

  // ----------------------------------------------------------

  // Previous samples

  // ใช้ตรวจสอบรูปร่างสัญญาณ

  // ----------------------------------------------------------

  // ignore: unused_field
  int _previous2 = 2048;

  int _previous1 = 2048;

  // ----------------------------------------------------------

  // Adaptive baseline

  // ----------------------------------------------------------

  double _baseline = 2048.0;

  // ----------------------------------------------------------

  // Adaptive signal envelope

  // ----------------------------------------------------------

  double _envelope = 20.0;

  // ----------------------------------------------------------

  // R-PEAK CANDIDATE

  //

  // เมื่อพบว่าสัญญาณเข้าสู่บริเวณ QRS

  // จะเปิดหน้าต่างค้นหายอดสูงสุดจริง

  // ----------------------------------------------------------

  bool _searchingPeak = false;

  // sample ที่เริ่มค้นหา R-Peak

  int _peakSearchStart = 0;

  // ค่า ADC สูงสุดที่พบในหน้าต่างค้นหา

  int _candidatePeakValue = 0;

  // sample number ของค่าสูงสุด

  int _candidatePeakSample = 0;

  // ----------------------------------------------------------

  // SEARCH WINDOW

  //

  // Fs = 200 Hz

  //

  // 120 ms × 200 Hz

  // = 24 samples

  // ----------------------------------------------------------

  static const int _peakSearchWindowSamples = 24;

  // ----------------------------------------------------------

  // REFRACTORY PERIOD

  //

  // 300 ms × 200 Hz

  // = 60 samples

  // ----------------------------------------------------------

  static const int _refractorySamples = 60;

  // ----------------------------------------------------------

  // R-PEAK POINTS

  // สำหรับแสดงจุดสีแดงบนกราฟ

  // ----------------------------------------------------------

  final List<int> _rPeakSamples = [];

  final List<int> _rPeakValues = [];

  // ==========================================================

  // NEW GRAPH

  // ==========================================================

  final limitCount = 100;

  final sinPoints = <FlSpot>[];

  double xValue = 0;

  double step = 0.05;

  late Timer timer;

  // ==========================================================

  // INIT

  // ==========================================================

  @override
  void initState() {
    super.initState();

    _restoreWebHistory();

    if (!kIsWeb) {
      _loadHistory();
    }

    // --------------------------------------------------------

    // UI update 10 FPS

    //

    // ECG sampling ยังคง 200 Hz

    // เพียงแต่หน้าจอ redraw ทุก 100 ms

    // --------------------------------------------------------

    _uiTimer = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      if (!mounted) return;

      // ----------------------------------------------------

      // ครบ 5 นาที

      // ----------------------------------------------------

      if (_recording &&
          _started != null &&
          DateTime.now().difference(_started!) >= sessionLength) {
        await _endSession(completed: true);
      }

      // ----------------------------------------------------

      // Update UI

      // ----------------------------------------------------

      if (_packetCount > 0 || _recording) {
        _packetCount = 0;

        setState(() {});
      }
    });
  }

  // ==========================================================

  // LOAD HISTORY

  // ==========================================================

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();

    try {
      final items = jsonDecode(prefs.getString('sessions') ?? '[]') as List;

      if (!mounted) return;

      setState(() {
        _history.addAll(
          items.map((item) => Map<String, dynamic>.from(item as Map)),
        );
      });
      //        ();
    } catch (_) {
      _show('อ่านประวัติไม่สำเร็จ');
    }
  }

  // ==========================================================

  // SHOW MESSAGE

  // ==========================================================

  void _show(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ==========================================================

  // SCAN BLUETOOTH

  // ==========================================================

  Future<void> _scan() async {
    if (_busy) return;

    setState(() {
      _busy = true;
      _status = 'กำลังค้นหาอุปกรณ์';
    });

    bool dialogOpen = false;

    try {
      // Mobile permissions only.
      if (!kIsWeb && Platform.isAndroid) {
        await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.locationWhenInUse,
        ].request();
      }

      if (!mounted) return;

      dialogOpen = true;

      final dialogFuture = showDialog<BluetoothDevice>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.bluetooth, color: Colors.blue),
                SizedBox(width: 8),
                Text('เลือกอุปกรณ์ Bluetooth'),
              ],
            ),
            content: SizedBox(
              width: 400,
              height: 320,
              child: StreamBuilder<List<ScanResult>>(
                stream: FlutterBluePlus.scanResults,
                initialData: const [],
                builder: (context, snapshot) {
                  final devices = snapshot.data ?? [];

                  if (devices.isEmpty) {
                    return const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 20),
                        Text('กำลังค้นหาอุปกรณ์ BLE...'),
                        SizedBox(height: 8),
                        Text('กรุณาเปิด ESP32-C3'),
                      ],
                    );
                  }

                  return ListView.separated(
                    itemCount: devices.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final result = devices[index];

                      final advertisedName = result.advertisementData.advName;

                      final platformName = result.device.platformName;

                      final name = advertisedName.isNotEmpty
                          ? advertisedName
                          : platformName.isNotEmpty
                          ? platformName
                          : 'Unknown device';

                      return ListTile(
                        leading: const Icon(
                          Icons.bluetooth,
                          color: Colors.blue,
                        ),
                        title: Text(name),
                        subtitle: Text(result.device.remoteId.toString()),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(dialogContext).pop(result.device);
                        },
                      );
                    },
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('ยกเลิก'),
              ),
            ],
          );
        },
      );

      // Chrome opens its Bluetooth chooser first.
      // Mobile scans nearby BLE devices.
      try {
        await FlutterBluePlus.startScan(
          timeout: const Duration(seconds: 15),
          webOptionalServices: kIsWeb ? [Guid(serviceId)] : [],
        );
      } catch (e) {
        if (mounted && dialogOpen) {
          Navigator.of(context, rootNavigator: true).pop();
        }

        _show('ค้นหาไม่สำเร็จ: $e');
      }

      final selectedDevice = await dialogFuture;
      dialogOpen = false;

      if (!kIsWeb) {
        await FlutterBluePlus.stopScan();
      }

      if (selectedDevice != null && mounted) {
        setState(() {
          _status = 'กำลังเชื่อมต่อ...';
        });

        await _connect(selectedDevice);
      }
    } catch (e) {
      _show('Bluetooth error: $e');
    } finally {
      if (!kIsWeb) {
        try {
          await FlutterBluePlus.stopScan();
        } catch (_) {}
      }

      if (mounted) {
        setState(() {
          _busy = false;

          if (!_connected) {
            _status = 'ยังไม่เชื่อมต่อ';
          }
        });
      }
    }
  }

  // Future<void> _scan() async {
  //   if (_busy) return;

  //   setState(() {
  //     _busy = true;

  //     _scanning = true;

  //     _status = 'กำลังค้นหา ESP32C3_ECG';
  //   });

  //   try {
  //     // ------------------------------------------------------

  //     // Android permission

  //     // ------------------------------------------------------

  //     if (!kIsWeb && Platform.isAndroid) {
  //       final permissions = await [
  //         Permission.bluetoothScan,

  //         Permission.bluetoothConnect,

  //         Permission.locationWhenInUse,
  //       ].request();

  //       if (permissions[Permission.bluetoothScan] != PermissionStatus.granted ||
  //           permissions[Permission.bluetoothConnect] !=
  //               PermissionStatus.granted) {
  //         throw Exception('กรุณาอนุญาต Bluetooth ในการตั้งค่าโทรศัพท์');
  //       }
  //     }

  //     // ------------------------------------------------------

  //     // Scan result listener

  //     // ------------------------------------------------------

  //     await _scanSub?.cancel();

  //     _scanSub = FlutterBluePlus.scanResults.listen((results) {
  //       for (final item in results) {
  //         final name1 = item.device.platformName;

  //         final name2 = item.advertisementData.advName;

  //         final found = name1 == 'ESP32C3_ECG' || name2 == 'ESP32C3_ECG';

  //         if (found && !_connecting) {
  //           _connecting = true;

  //           if (!kIsWeb) {
  //             FlutterBluePlus.stopScan();
  //           }

  //           _connect(item.device);

  //           break;
  //         }
  //       }
  //     });

  //     // ------------------------------------------------------

  //     // Start Scan

  //     // ------------------------------------------------------

  //     await FlutterBluePlus.startScan(
  //       timeout: const Duration(seconds: 12),

  //       withServices: kIsWeb ? [Guid(serviceId)] : [],

  //       webOptionalServices: kIsWeb ? [Guid(serviceId)] : [],
  //     );

  //     // Android/iOS wait scan
  //     if (!kIsWeb) {
  //       await Future.delayed(const Duration(seconds: 12));
  //     }

  //     if (!_connected && mounted) {
  //       setState(() {
  //         _status = 'ไม่พบอุปกรณ์ ESP32C3_ECG';
  //       });
  //     }
  //   } catch (e) {
  //     _show('ค้นหาไม่สำเร็จ: $e');
  //   } finally {
  //     await _scanSub?.cancel();

  //     _scanSub = null;

  //     if (mounted) {
  //       setState(() {
  //         _busy = false;

  //         _scanning = false;
  //       });
  //     }
  //   }
  // }

  // ==========================================================

  // CONNECT

  // ==========================================================

  Future<void> _connect(BluetoothDevice device) async {
    try {
      // ------------------------------------------------------

      // Disconnect old device

      // ------------------------------------------------------

      if (_device != null && _device != device) {
        await _disconnect();
      }

      _device = device;

      // ------------------------------------------------------

      // Connect

      // ------------------------------------------------------

      await device.connect(
        license: License.free,

        timeout: const Duration(seconds: 15),
      );

      // ------------------------------------------------------

      // Connection state

      // ------------------------------------------------------

      await _connectionSub?.cancel();

      _connectionSub = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected && mounted) {
          _ecgSub?.cancel();

          _ecgSub = null;

          _characteristic = null;

          setState(() {
            _connected = false;

            _status = 'การเชื่อมต่อขาด';
          });

          if (_recording) {
            _endSession(completed: false);
          }
        }
      });

      // ------------------------------------------------------

      // Discover services

      // ------------------------------------------------------

      final services = await device.discoverServices();

      BluetoothCharacteristic? target;

      // ------------------------------------------------------

      // Find Service + Characteristic

      // ------------------------------------------------------

      for (final service in services) {
        final currentService = service.uuid.toString().toLowerCase();

        if (currentService != serviceId.toLowerCase()) {
          continue;
        }

        for (final characteristic in service.characteristics) {
          final currentCharacteristic = characteristic.uuid
              .toString()
              .toLowerCase();

          if (currentCharacteristic == ecgId.toLowerCase()) {
            target = characteristic;

            break;
          }
        }

        if (target != null) {
          break;
        }
      }

      // ------------------------------------------------------

      // Characteristic not found

      // ------------------------------------------------------

      if (target == null) {
        throw Exception('ไม่พบ ECG Characteristic UUID');
      }

      _characteristic = target;

      // ------------------------------------------------------

      // ECG notification listener

      // ------------------------------------------------------

      // await _ecgSub?.cancel();

      // _ecgSub = target.onValueReceived.listen(
      //   _onPacket,

      //   onError: (error) {
      //     if (mounted) {
      //       _show('รับข้อมูล ECG ผิดพลาด: $error');
      //     }
      //   },
      // );

      // ------------------------------------------------------

      // Enable notify

      // ------------------------------------------------------

      // await target.setNotifyValue(true);
      // _characteristic = target;

      // ------------------------------------------------------

      // Connected

      // ------------------------------------------------------

      if (!mounted) return;

      setState(() {
        _connected = true;

        _status = 'เชื่อมต่อ ESP32C3_ECG';
      });
    } catch (e) {
      _show('เชื่อมต่อไม่สำเร็จ: $e');

      await _disconnect();
    } finally {
      _connecting = false;
    }
  }

  // ==========================================================

  // DISCONNECT

  // ==========================================================

  Future<void> _disconnect() async {
    if (_recording) {
      await _endSession(completed: false);
    }

    await _ecgSub?.cancel();

    _ecgSub = null;
    await _connectionSub?.cancel();

    _connectionSub = null;

    final device = _device;

    _device = null;

    _characteristic = null;

    try {
      await device?.disconnect();
    } catch (_) {}

    if (!mounted) return;

    setState(() {
      _connected = false;

      _status = 'ยังไม่เชื่อมต่อ';
    });
  }

  // ==========================================================

  // RECEIVE BLE PACKET

  //

  // ESP32 ส่ง:

  //

  // 10 samples

  // uint16 little-endian

  //

  // 10 × 2 = 20 bytes

  // ==========================================================

  void _onPacket(List<int> bytes) {
    if (!_recording) return;

    if (bytes.length != 20) {
      return;
    }

    // --------------------------------------------------------

    // 20 bytes

    // อ่านทีละ 2 bytes

    // --------------------------------------------------------

    for (int i = 0; i < 20; i += 2) {
      // ------------------------------------------------------

      // Little endian

      //

      // low byte + high byte

      // ------------------------------------------------------

      final int value = bytes[i] | (bytes[i + 1] << 8);
      // Save raw ECG ADC data before R-peak processing
      _rawEcgSamples.add(value);
      _sampleIndex++;

      // ------------------------------------------------------

      // ECG BUFFER

      // ------------------------------------------------------

      _trace.add(value);

      // เก็บ 5 วินาที

      //

      // 200 × 5 = 1000 samples

      if (_trace.length > maxTraceSamples) {
        _trace.removeRange(0, _trace.length - maxTraceSamples);
      }

      // ------------------------------------------------------

      // SAVE ECG

      // ------------------------------------------------------

      // if (_recording) {
      //   // 200 Hz

      //   //

      //   // 1 sample = 5 ms

      //   final elapsedMs = _sessionSamples * 5;

      //   final row = '$elapsedMs,$value';

      //   if (kIsWeb) {
      //     _webCsv?.writeln(row);
      //   } else {
      //     _sink?.writeln(row);
      //   }

      //   _sessionSamples++;
      // }

      if (_recording) {
        _sessionSamples++;
      }
      // ------------------------------------------------------

      // R PEAK

      // ------------------------------------------------------

      _detectRPeak(value);

      // ------------------------------------------------------

      // Shift samples

      // ------------------------------------------------------

      _previous2 = _previous1;

      _previous1 = value;
    }

    _packetCount++;
  }

  // ==========================================================

  // R-PEAK DETECTION

  // ==========================================================

  // ==========================================================
  // R-PEAK DETECTION
  // ==========================================================

  void _detectRPeak(int value) {
    // 1. Estimate baseline
    _baseline += 0.003 * (value - _baseline);

    final double signal = value - _baseline;
    final double amplitude = signal.abs();

    // 2. Adaptive envelope
    _envelope += 0.002 * (amplitude - _envelope);
    // debugPrint(amplitude.toString());
    // ใช้ threshold ป้องกันสัญญาณขนาดเล็ก
    final double threshold = max(25, _envelope * 1.5);
    // final double threshold = 10;
    // 3. Start candidate search
    if (!_searchingPeak) {
      final bool outsideRefractory =
          _lastPeakSample == null ||
          (_sampleIndex - _lastPeakSample!) >= _refractorySamples;

      // if (outsideRefractory && amplitude > threshold) {
      //   _searchingPeak = true;
      //   _peakSearchStart = _sampleIndex;
      //   _candidatePeakSample = _sampleIndex;
      //   _candidatePeakValue = value;
      // }
      if (outsideRefractory && signal > threshold) {
        _searchingPeak = true;
        _peakSearchStart = _sampleIndex;
        _candidatePeakSample = _sampleIndex;
        _candidatePeakValue = value;
      }
      return;
    }

    // 4. Track the largest absolute deviation from baseline

    final double candidateAmplitude = (_candidatePeakValue - _baseline).abs();

    if (amplitude > candidateAmplitude) {
      _candidatePeakValue = value;
      _candidatePeakSample = _sampleIndex;
    }

    // Wait until the search window has elapsed
    if (_sampleIndex - _peakSearchStart < _peakSearchWindowSamples) {
      return;
    }

    _searchingPeak = false;

    final int peakSample = _candidatePeakSample;
    final int peakValue = _candidatePeakValue;

    final int? previousPeakSample = _lastPeakSample;

    // Reset candidate before returning
    _candidatePeakValue = 0;

    // 5. Refractory check
    if (previousPeakSample != null &&
        peakSample - previousPeakSample < _refractorySamples) {
      return;
    }

    // 6. Store peak for the real-time graph
    _rPeakSamples.add(peakSample);
    _rPeakValues.add(peakValue);
    debugPrint(
      'R-PEAK DETECTED: sample=$peakSample, '
      'ADC=$peakValue, '
      'time=${(peakSample / sampleRate).toStringAsFixed(3)} s',
    );
    final int oldestPeakToKeep = _sampleIndex - maxTraceSamples - sampleRate;

    while (_rPeakSamples.isNotEmpty && _rPeakSamples.first < oldestPeakToKeep) {
      _rPeakSamples.removeAt(0);
      _rPeakValues.removeAt(0);
    }

    // 7. Calculate RR interval
    if (previousPeakSample != null) {
      final int sampleDifference = peakSample - previousPeakSample;

      final int candidateRR = (sampleDifference * 1000.0 / sampleRate).round();

      final double hr = candidateRR > 0 ? 60000.0 / candidateRR : 0.0;

      // Sample index in this app starts at 1
      final double peakTimeSeconds = (peakSample - 1) / sampleRate.toDouble();

      // 8. Basic physiological range check

      String status = 'VALID';
      String rejectReason = '';

      // ตรวจสอบช่วง RR
      if (candidateRR < 300 || candidateRR > 2000) {
        status = 'REJECTED';
        rejectReason = 'RR_OUT_OF_RANGE';
      }

      // ตรวจสอบความต่างจาก RR ก่อนหน้า
      if (status == 'VALID' && _rrIntervals.isNotEmpty) {
        final int previousValidRR = _rrIntervals.last;
        final int rrDifference = (candidateRR - previousValidRR).abs();

        if (rrDifference > 200) {
          status = 'REJECTED';
          rejectReason = 'RR_CHANGE_TOO_LARGE';
        }
      }

      debugPrint(
        'RR CHECK: RR=$candidateRR ms | '
        'previousValidRR=${_rrIntervals.isEmpty ? "NONE" : _rrIntervals.last} | '
        'status=$status | '
        'reason=${rejectReason.isEmpty ? "NONE" : rejectReason}',
      );

      // 9. Save RR records only during recording
      if (_recording) {
        _rrRecords.add({
          'index': _rrRecords.length + 1,
          'rPeakSample': peakSample,
          'time': peakTimeSeconds,
          'rr': candidateRR,
          'hr': hr,
          'status': status,
        });

        if (status == 'VALID') {
          _rrIntervals.add(candidateRR);
        }
      }

      if (status == 'VALID') {
        _lastRR = candidateRR;
      }

      debugPrint(
        'R-PEAK $previousPeakSample -> $peakSample | '
        'RR=$candidateRR ms | '
        'HR=${hr.toStringAsFixed(1)} bpm | $status',
      );
    }

    // Update last detected peak even when its RR is rejected.
    // This prevents the next RR interval from spanning two beats.
    _lastPeakSample = peakSample;
  }

  // ==========================================================

  // START 5-MINUTE SESSION

  // ==========================================================

  Future<void> _startSession() async {
    if (!_connected || _recording) {
      return;
    }

    final characteristic = _characteristic;

    if (characteristic == null) {
      _show('ไม่พบ ECG Characteristic');
      return;
    }

    // Start receiving data only when the button is pressed.
    try {
      await _ecgSub?.cancel();

      _ecgSub = characteristic.onValueReceived.listen(
        _onPacket,
        onError: (error) {
          if (mounted) {
            _show('รับข้อมูล ECG ผิดพลาด: $error');
          }
        },
      );

      await characteristic.setNotifyValue(true);
    } catch (e) {
      await _ecgSub?.cancel();
      _ecgSub = null;

      _show('เริ่มรับข้อมูลไม่สำเร็จ: $e');
      return;
    }

    final DateTime start = DateTime.now();

    setState(() {
      _started = start;
      _sessionSamples = 0;
      _rawEcgSamples.clear();
      // Reset RR data.
      _rrIntervals.clear();
      _rrRecords.clear();

      // Reset R-peak detection.

      _lastRR = null;
      _lastPeakSample = null;

      _searchingPeak = false;
      _peakSearchStart = 0;
      _candidatePeakValue = 0;
      _candidatePeakSample = 0;

      // Reset adaptive detector state
      _baseline = 2048.0;
      _envelope = 20.0;

      // Reset previous samples
      _previous1 = 2048;
      _previous2 = 2048;

      _rPeakSamples.clear();
      _rPeakValues.clear();

      // Start recording.
      _recording = true;

      // Clear the previous graph trace for a fresh session.
      _trace.clear();
      _sampleIndex = 0;
    });

    _show('เริ่มบันทึกข้อมูล 5 นาที');
  }

  // ==========================================================
  // BAEVSKY STRESS INDEX
  // ==========================================================

  double? _calculateStressIndex(List<int> rrValues) {
    // ต้องมีข้อมูลเพียงพอ
    if (rrValues.length < 2) {
      return null;
    }

    // --------------------------------------------------------
    // Histogram bin width = 50 ms
    // --------------------------------------------------------

    const int binWidthMs = 50;

    final Map<int, int> histogram = <int, int>{};

    for (final int rr in rrValues) {
      final int bin = rr ~/ binWidthMs;

      histogram[bin] = (histogram[bin] ?? 0) + 1;
    }

    if (histogram.isEmpty) {
      return null;
    }

    // --------------------------------------------------------
    // Find modal bin
    // --------------------------------------------------------

    int modalBin = 0;
    int modalCount = 0;

    histogram.forEach((int bin, int count) {
      if (count > modalCount) {
        modalCount = count;
        modalBin = bin;
      }
    });

    // --------------------------------------------------------
    // Mo
    //
    // ใช้ค่ากึ่งกลางของ modal bin
    // convert ms -> seconds
    // --------------------------------------------------------

    final double modeMs = modalBin * binWidthMs + binWidthMs / 2.0;

    final double mo = modeMs / 1000.0;

    // --------------------------------------------------------
    // AMo (%)
    // --------------------------------------------------------

    final double amo = (modalCount / rrValues.length) * 100.0;

    // --------------------------------------------------------
    // MxDMn
    // --------------------------------------------------------

    final int minRR = rrValues.reduce(min);

    final int maxRR = rrValues.reduce(max);

    final double rangeSeconds = (maxRR - minRR) / 1000.0;

    if (mo <= 0 || rangeSeconds <= 0) {
      return null;
    }

    // --------------------------------------------------------
    // Stress Index
    // --------------------------------------------------------

    return amo / (2.0 * mo * rangeSeconds);
  }
  // ==========================================================

  // END SESSION

  // ==========================================================

  Future<void> _endSession({required bool completed}) async {
    if (!_recording) {
      return;
    }

    _recording = false;

    await _ecgSub?.cancel();
    _ecgSub = null;

    try {
      await _characteristic?.setNotifyValue(false);
    } catch (e) {
      debugPrint('Failed to dusable ECG notifications: $e');
    }

    final DateTime start = _started ?? DateTime.now();

    _started = null;

    try {
      // ======================================================
      // FILE NAME
      // ======================================================

      final String timestamp = start.toIso8601String().replaceAll(':', '-');

      final String rawFilename = 'Raw_ECG_$timestamp.csv';

      final String rrFilename = 'RR_Record_$timestamp.csv';

      final String kubiosFilename = 'Kubios_RR_$timestamp.csv';

      // ======================================================
      // FILE 1
      //
      // Index
      // R Peak Sample
      // Time
      // RR
      // HR
      // Status
      // ======================================================

      final StringBuffer rrCsv = StringBuffer();

      rrCsv.writeln('Index,R Peak Sample,Time (s),RR (ms),HR (bpm),Status');

      for (final Map<String, dynamic> record in _rrRecords) {
        final int index = record['index'] as int;

        final int rPeakSample = record['rPeakSample'] as int;

        final double time = record['time'] as double;

        final int rr = record['rr'] as int;

        final double hr = record['hr'] as double;

        final String status = record['status'] as String;

        rrCsv.writeln(
          '$index,'
          '$rPeakSample,'
          '${time.toStringAsFixed(3)},'
          '$rr,'
          '${hr.toStringAsFixed(2)},'
          '$status',
        );
      }

      // ======================================================
      // FILE 2
      // KUBIOS
      //
      // VALID RR ONLY
      // ======================================================

      final StringBuffer kubiosCsv = StringBuffer();

      for (final int rr in _rrIntervals) {
        kubiosCsv.writeln(rr);
      }
      // FILE: RAW ECG DATA
      final StringBuffer rawCsv = StringBuffer();

      rawCsv.writeln('Sample,Time (ms),Raw ADC');

      for (int i = 0; i < _rawEcgSamples.length; i++) {
        final int rawValue = _rawEcgSamples[i];
        final int timeMs = (i * 1000 / sampleRate).round();

        rawCsv.writeln('${i + 1},$timeMs,$rawValue');
      }
      // ======================================================
      // SAVE
      // ======================================================

      String rrPath;
      String kubiosPath;
      String rawPath;

      if (kIsWeb) {
        rrPath = rrFilename;
        kubiosPath = kubiosFilename;
        rawPath = rawFilename;

        _webFiles[rrPath] = rrCsv.toString();
        _webFiles[kubiosPath] = kubiosCsv.toString();
        _webFiles[rawPath] = rawCsv.toString();
      } else {
        final directory = await getApplicationDocumentsDirectory();

        rrPath = '${directory.path}/$rrFilename';
        kubiosPath = '${directory.path}/$kubiosFilename';
        rawPath = '${directory.path}/$rawFilename';

        await File(rrPath).writeAsString(rrCsv.toString());
        await File(kubiosPath).writeAsString(kubiosCsv.toString());
        await File(rawPath).writeAsString(rawCsv.toString());
      }

      // if (kIsWeb) {
      //   // ----------------------------------------------------
      //   // WEB
      //   // ----------------------------------------------------

      //   rrPath = rrFilename;

      //   kubiosPath = kubiosFilename;

      //   _webFiles[rrPath] = rrCsv.toString();

      //   _webFiles[kubiosPath] = kubiosCsv.toString();
      // } else {
      //   // ----------------------------------------------------
      //   // ANDROID / MOBILE
      //   // ----------------------------------------------------

      //   final directory = await getApplicationDocumentsDirectory();

      //   rrPath = '${directory.path}/$rrFilename';

      //   kubiosPath = '${directory.path}/$kubiosFilename';

      //   await File(rrPath).writeAsString(rrCsv.toString());

      //   await File(kubiosPath).writeAsString(kubiosCsv.toString());
      // }

      // ======================================================
      // HRV CALCULATION
      // ======================================================

      final List<int> rrValues = List<int>.from(_rrIntervals);

      double? meanRR;
      double? meanHR;
      double? sdnn;
      double? rmssd;
      double? sdsd;

      // Poincaré
      double? sd1;
      double? sd2;

      // Baevsky Stress Index
      double? stressIndex;

      final List<double> differences = [];

      // ------------------------------------------------------
      // MEAN RR / HR
      // ------------------------------------------------------

      if (rrValues.isNotEmpty) {
        meanRR = rrValues.reduce((a, b) => a + b) / rrValues.length;

        meanHR = 60000.0 / meanRR;
      }

      // ------------------------------------------------------
      // SDNN
      // ------------------------------------------------------

      if (rrValues.length >= 2 && meanRR != null) {
        double sum = 0.0;

        for (final int rr in rrValues) {
          final double d = rr - meanRR;

          sum += d * d;
        }

        sdnn = sqrt(sum / (rrValues.length - 1));
      }

      // ------------------------------------------------------
      // RR DIFFERENCES
      // ------------------------------------------------------

      for (int i = 1; i < rrValues.length; i++) {
        differences.add((rrValues[i] - rrValues[i - 1]).toDouble());
      }

      // ------------------------------------------------------
      // RMSSD
      // ------------------------------------------------------

      if (differences.isNotEmpty) {
        double sum = 0.0;

        for (final double difference in differences) {
          sum += difference * difference;
        }

        rmssd = sqrt(sum / differences.length);
      }

      // ------------------------------------------------------
      // SDSD
      // ------------------------------------------------------

      if (differences.length >= 2) {
        final double meanDifference =
            differences.reduce((a, b) => a + b) / differences.length;

        double sum = 0.0;

        for (final double difference in differences) {
          final double d = difference - meanDifference;

          sum += d * d;
        }

        sdsd = sqrt(sum / (differences.length - 1));
      }

      stressIndex = _calculateStressIndex(rrValues);

      // ==========================================================
      // POINCARÉ SD1 / SD2
      // ==========================================================
      //
      // SD1 = RMSSD / sqrt(2)
      //
      // SD2 = sqrt(
      //          2 * SDNN^2
      //          - 0.5 * RMSSD^2
      //       )
      //
      // Unit = ms
      // ==========================================================

      if (rmssd != null) {
        sd1 = rmssd / sqrt(2.0);
      }

      if (sdnn != null && rmssd != null) {
        final double sd2Squared = 2.0 * sdnn * sdnn - 0.5 * rmssd * rmssd;

        // ป้องกัน sqrt ของค่าติดลบ
        if (sd2Squared >= 0) {
          sd2 = sqrt(sd2Squared);
        }
      }

      // ======================================================
      // REJECTED COUNT
      // ======================================================

      final int rejectedCount = _rrRecords
          .where((record) => record['status'] == 'REJECTED')
          .length;

      // ======================================================
      // HISTORY
      // ======================================================

      final Map<String, dynamic> item = <String, dynamic>{
        'start': start.toIso8601String(),

        // ไฟล์ตาราง RR
        'path': rrPath,

        'rrPath': rrPath,

        // ไฟล์สำหรับ Kubios
        'kubiosPath': kubiosPath,

        'completed': completed,

        'samples': _sessionSamples,

        'meanRR': meanRR,

        'meanHr': meanHR,

        'sdnn': sdnn,

        'rmssd': rmssd,

        'sdsd': sdsd,

        // Poincaré
        'sd1': sd1,
        'sd2': sd2,

        // Stress
        'stressIndex': stressIndex,

        'rrCount': rrValues.length,

        'rrPairCount': differences.length,

        'rejectedCount': rejectedCount,

        'rawPath': rawPath,

        'rawSamples': _rawEcgSamples.length,

        'rrValues': List<int>.from(rrValues),
      };

      _history.insert(0, item);

      // Persist lightweight history metadata on the web.
      if (kIsWeb) {
        _persistWebHistory();
      } else {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('sessions', jsonEncode(_history));
      }

      // ======================================================
      // SAVE HISTORY
      // ======================================================

      if (!kIsWeb) {
        final prefs = await SharedPreferences.getInstance();

        await prefs.setString('sessions', jsonEncode(_history));
      }

      if (mounted) {
        setState(() {});
      }

      // ======================================================
      // MESSAGE
      // ======================================================

      if (completed) {
        _show('บันทึกครบ 5 นาทีแล้ว');
      } else {
        _show('หยุดและบันทึกข้อมูลแล้ว');
      }
    } catch (e) {
      _show('บันทึกข้อมูลไม่สำเร็จ: $e');
    }
  }

  // ==========================================================

  // SHARE CSV

  // ==========================================================

  Future<void> _share(Map<String, dynamic> item) async {
    final String path = item['path'] as String;

    if (kIsWeb) {
      final String? content = _webFiles[path];

      if (content == null) {
        _show('ไม่พบไฟล์ CSV ของรอบนี้');
        return;
      }

      String filename = path.replaceAll('\\', '/').split('/').last;

      if (filename.isEmpty) {
        filename = 'ECG_5min.csv';
      } else if (!filename.toLowerCase().endsWith('.csv')) {
        filename += '.csv';
      }

      try {
        final bool saved = await csv_save.saveCsvFile(filename, content);

        if (!mounted) return;

        if (saved) {
          _show('บันทึกไฟล์ CSV เรียบร้อยแล้ว');
        }
      } catch (e) {
        if (!mounted) return;
        _show('บันทึกไฟล์ไม่สำเร็จ: $e');
      }

      return;
    }

    // Mobile: keep the existing share behavior.
    final File file = File(path);

    if (!await file.exists()) {
      if (!mounted) return;
      _show('ไม่พบไฟล์ CSV ของรอบนี้');
      return;
    }

    await Share.shareXFiles([
      XFile(file.path, mimeType: 'text/csv'),
    ], text: 'ECG 5-minute session');
  }

  Future<void> _shareRaw(Map<String, dynamic> item) async {
    final String? path = item['rawPath'] as String?;

    if (path == null || path.isEmpty) {
      _show('ไม่พบไฟล์ Raw ECG ของรอบนี้');
      return;
    }

    if (kIsWeb) {
      final String? content = _webFiles[path];

      if (content == null) {
        _show('ไม่พบไฟล์ Raw ECG ในหน่วยความจำ กรุณาวัดใหม่');
        return;
      }

      final filename = path.split('/').last;

      final bool saved = await csv_save.saveCsvFile(filename, content);

      if (mounted && saved) {
        _show('บันทึกไฟล์ Raw ECG เรียบร้อยแล้ว');
      }

      return;
    }

    final File file = File(path);

    if (!await file.exists()) {
      _show('ไม่พบไฟล์ Raw ECG ของรอบนี้');
      return;
    }

    await Share.shareXFiles([
      XFile(file.path, mimeType: 'text/csv'),
    ], text: 'Raw ECG Data');
  }

  // ==========================================================
  // ต้องเป็นฟังก์ชันแยก ไม่อยู่ข้างใน _share()
  // ==========================================================

  Future<void> _shareKubios(Map<String, dynamic> item) async {
    final String? path = item['kubiosPath'] as String?;

    if (path == null || path.isEmpty) {
      _show('รอบนี้ยังไม่มีไฟล์ Kubios CSV');
      return;
    }

    if (kIsWeb) {
      final String? content = _webFiles[path];

      if (content == null) {
        _show('ไม่พบไฟล์ Kubios CSV');
        return;
      }

      await Share.shareXFiles(
        [XFile.fromData(utf8.encode(content), mimeType: 'text/csv')],
        fileNameOverrides: [path],
        text: 'RR Interval for Kubios HRV',
      );

      return;
    }

    final File file = File(path);

    if (!await file.exists()) {
      _show('ไม่พบไฟล์ Kubios CSV');
      return;
    }

    await Share.shareXFiles([
      XFile(file.path, mimeType: 'text/csv'),
    ], text: 'RR Interval for Kubios HRV');
  }

  // Keep Data History =======================================

  // ============================================================
  // WEB HISTORY - SAVE LIGHTWEIGHT METADATA ONLY
  // ============================================================

  void _persistWebHistory() {
    if (!kIsWeb) return;

    try {
      // Keep only the newest 50 history records.
      // Do not put large CSV strings into browser storage.
      final records = _history.take(50).map((item) {
        final copy = Map<String, dynamic>.from(item);

        // Raw RR values are not needed to display the history cards.
        copy.remove('rrValues');

        return copy;
      }).toList();

      final content = jsonEncode({'history': records});

      history_storage.writeHistory(content);
    } catch (e) {
      debugPrint('Save web history failed: $e');
    }
  }

  void _restoreWebHistory() {
    if (!kIsWeb) return;

    try {
      final content = history_storage.readHistory();

      if (content == null || content.isEmpty) return;

      final data = Map<String, dynamic>.from(jsonDecode(content) as Map);

      final rawHistory = data['history'];

      if (rawHistory is! List) return;

      final records = rawHistory
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .take(50)
          .toList();

      _history
        ..clear()
        ..addAll(records);

      // CSV files are kept in memory separately.
      // Old CSV files must be restored from persistent file storage
      // if exporting them after a page reload is required.
    } catch (e) {
      debugPrint('Restore web history failed: $e');
    }
  }

  // ==========================================================

  // CLOCK

  // ==========================================================

  String _clock(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');

    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');

    return '$minutes:$seconds';
  }

  // ==========================================================

  // FORMAT METRIC

  // ==========================================================

  String _metric(dynamic value, {int digits = 1}) {
    if (value == null) {
      return '—';
    }

    return (value as num).toStringAsFixed(digits);
  }

  Future<void> _deleteHistoryItem(Map<String, dynamic> item) async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Delete history?'),
          content: const Text('คุณต้องการลบข้อมูลการวัดรายการนี้หรือไม่?'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext, false);
              },
              child: const Text('ยกเลิก'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext, true);
              },
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('ลบข้อมูล'),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    setState(() {
      _history.remove(item);
    });

    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('ลบประวัติการวัดแล้ว')));
  }

  // ==========================================================

  // BUILD

  // ==========================================================

  @override
  Widget build(BuildContext context) {
    // --------------------------------------------------------

    // SESSION TIME

    // --------------------------------------------------------

    final elapsed = _started == null
        ? Duration.zero
        : DateTime.now().difference(_started!);

    final double progress =
        (elapsed.inMilliseconds / sessionLength.inMilliseconds).clamp(0.0, 1.0);

    // ========================================================

    // ECG Y-AXIS

    //

    // สำคัญ:

    // ไม่ใช้ min/max ของ ECG มาขยายกราฟทุก frame

    //

    // ใช้ช่วง Y คงที่ 1000 ADC

    // และให้ center เคลื่อนตามค่าเฉลี่ย

    // ========================================================

    // ========================================================

    // ECG AUTO Y AXIS

    // ========================================================

    double chartMinY = 1900;

    double chartMaxY = 2400;

    if (_trace.isNotEmpty) {
      final double minValue = _trace.reduce((a, b) => a < b ? a : b).toDouble();

      final double maxValue = _trace.reduce((a, b) => a > b ? a : b).toDouble();

      final double range = maxValue - minValue;

      // เพิ่มพื้นที่ด้านบน/ล่าง 15%

      double padding = range * 0.15;

      // ป้องกันกราฟแน่นเกินไป

      if (padding < 30) {
        padding = 30;
      }

      chartMinY = minValue - padding;

      chartMaxY = maxValue + padding;

      chartMinY = chartMinY.clamp(0.0, 4095.0);

      chartMaxY = chartMaxY.clamp(0.0, 4095.0);
    }

    // ========================================================

    // CREATE ECG POINTS

    //

    // 1000 samples = 5 seconds

    // ========================================================

    // ========================================================

    // REAL-TIME X AXIS

    // ========================================================

    // เวลาปัจจุบันจากจำนวน sample ที่รับมา

    final double currentTime = _sampleIndex / sampleRate;

    // กราฟแสดงย้อนหลัง 5 วินาที

    final double chartMaxX = currentTime < graphSeconds
        ? graphSeconds.toDouble()
        : currentTime;

    final double chartMinX = currentTime < graphSeconds
        ? 0.0
        : currentTime - graphSeconds;

    // sample แรกที่อยู่ใน _trace

    final int firstSampleIndex = _sampleIndex - _trace.length + 1;

    // สร้างจุด ECG

    final List<FlSpot> ecgSpots = List.generate(_trace.length, (i) {
      final int sampleNumber = firstSampleIndex + i;

      // X = เวลา

      final double time = sampleNumber / sampleRate.toDouble();

      // Y = แปลง ADC 0–4095 เป็น Voltage 0–3.3 V

      final double voltage = (_trace[i] / 4095.0) * 3.3;

      return FlSpot(time, voltage);
    });

    // ========================================================

    // R-PEAK SPOTS

    // ========================================================

    final List<FlSpot> rPeakSpots = [];

    for (int i = 0; i < _rPeakSamples.length; i++) {
      final int sampleNumber = _rPeakSamples[i];
      final double time = sampleNumber / sampleRate;

      // Show only peaks inside the visible graph window.
      if (time < chartMinX || time > chartMaxX) {
        continue;
      }

      final double voltage = (_rPeakValues[i] / 4095.0) * 3.3;

      rPeakSpots.add(FlSpot(time, voltage));
    }

    // ========================================================

    // CURRENT HR

    // ========================================================

    final String currentHR = _lastRR == null
        ? '—'
        : '${(60000 / _lastRR!).round()} bpm';

    final String currentRR = _lastRR == null ? '—' : '$_lastRR ms';

    // ========================================================

    // PAGE

    // ========================================================

    // ========================================================

    // AUTO Y AXIS

    // ECG data: ADC -> Voltage

    // ========================================================

    double chartMinY2 = 0.0;

    double chartMaxY2 = 3.3;

    if (_trace.isNotEmpty) {
      // Find minimum and maximum ADC values

      final int minADC = _trace.reduce((a, b) => a < b ? a : b);

      final int maxADC = _trace.reduce((a, b) => a > b ? a : b);

      // Convert ADC -> Voltage

      final double minVoltage = (minADC / 4095.0) * 3.3;

      final double maxVoltage = (maxADC / 4095.0) * 3.3;

      // Signal range

      double range = maxVoltage - minVoltage;

      // Prevent Y-axis from becoming too narrow

      if (range < 0.05) {
        range = 0.05;
      }

      // Add 20% margin above and below

      final double margin = range * 0.10;

      chartMinY2 = (minVoltage - margin).clamp(0.0, 3.3);

      chartMaxY2 = (maxVoltage + margin).clamp(0.0, 3.3);
    }

    final double yInterval = (chartMaxY - chartMinY) / 2;

    // ========================================================

    // R-PEAK RED DOTS

    // ========================================================

    return Scaffold(
      // ------------------------------------------------------

      // APP BAR

      // ------------------------------------------------------
      appBar: AppBar(
        title: const Text('ECG Monitor'),

        backgroundColor: const Color(0xff123668),

        foregroundColor: Colors.white,

        actions: [
          PopupMenuButton<String>(
            // Triggers when a menu item is tapped

            onSelected: (String value) {
              switch (value) {
                case 'settings':

                  // Navigate to settings page

                  break;

                case 'logout':

                  // Handle user logout

                  break;
              }
            },

            itemBuilder: (BuildContext context) {
              return [
                const PopupMenuItem<String>(
                  value: 'settings',

                  child: Text('ปรับค่าแกน Y'),
                ),

                const PopupMenuItem<String>(
                  value: 'logout',

                  child: Text('Logout'),
                ),
              ];
            },
          ),

          const SizedBox(width: 10),
        ],
      ),

      // ------------------------------------------------------

      // BODY

      // ------------------------------------------------------
      body: ListView(
        padding: const EdgeInsets.all(16),

        children: [
          // ==================================================

          // BLUETOOTH CARD

          // ==================================================
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),

              child: Row(
                children: [
                  Icon(
                    Icons.bluetooth,

                    color: _connected ? Colors.green : Colors.grey,
                  ),

                  const SizedBox(width: 10),

                  Expanded(child: Text(_status)),

                  TextButton(
                    onPressed: _busy
                        ? null
                        : (_connected ? _disconnect : _scan),

                    child: Text(
                      _connected
                          ? 'ตัดการเชื่อมต่อ'
                          : _scanning
                          ? 'กำลังค้นหา'
                          : 'ค้นหาอุปกรณ์',
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 8),

          // ==================================================

          // ECG CARD

          // ==================================================
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),

              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,

                children: [
                  // ------------------------------------------

                  // ECG TITLE

                  // ------------------------------------------
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'สัญญาณ ECG แบบเรียลไทม์',

                          style: TextStyle(
                            fontSize: 17,

                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),

                      Text(
                        _connected ? '● LIVE' : 'OFFLINE',

                        style: TextStyle(
                          color: _connected ? Colors.green : Colors.grey,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // ==========================================

                  // ECG GRAPH

                  // ==========================================
                  SizedBox(
                    height: 250,

                    child: LineChart(
                      LineChartData(
                        // ======================================

                        // X AXIS - REAL TIME

                        // ======================================
                        minX: chartMinX,

                        maxX: chartMaxX,

                        // ======================================

                        // Y AXIS - VOLTAGE

                        // Fixed scale ป้องกันกราฟเด้ง

                        // ======================================
                        minY: chartMinY2,

                        maxY: chartMaxY2,

                        // minY: chartMinY,

                        // maxY: chartMaxY,

                        // ======================================

                        // TOUCH

                        // ======================================
                        lineTouchData: const LineTouchData(enabled: false),

                        // ======================================

                        // CLIP

                        // ======================================
                        clipData: const FlClipData.all(),

                        // ======================================

                        // GRID

                        // ======================================
                        gridData: FlGridData(
                          show: true,

                          drawVerticalLine: true,

                          drawHorizontalLine: true,

                          verticalInterval: 1.0,

                          horizontalInterval: yInterval,
                        ),

                        // ======================================

                        // BORDER

                        // ======================================
                        borderData: FlBorderData(
                          show: true,

                          border: Border.all(color: Colors.black12),
                        ),

                        // ======================================

                        // AXIS TITLES

                        // ======================================
                        titlesData: FlTitlesData(
                          topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),

                          rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),

                          bottomTitles: AxisTitles(
                            axisNameWidget: const Text('Time (s)'),

                            sideTitles: SideTitles(
                              showTitles: true,

                              interval: 1.0,

                              reservedSize: 30,

                              getTitlesWidget: (value, meta) {
                                return Text(
                                  value.toStringAsFixed(0),

                                  style: const TextStyle(fontSize: 10),
                                );
                              },
                            ),
                          ),

                          leftTitles: AxisTitles(
                            axisNameWidget: const Text('Voltage (V)'),

                            sideTitles: SideTitles(
                              showTitles: true,

                              interval: 0.825,

                              reservedSize: 48,

                              getTitlesWidget: (value, meta) {
                                return Text(
                                  value.toStringAsFixed(1),

                                  style: const TextStyle(fontSize: 10),
                                );
                              },
                            ),
                          ),
                        ),

                        // ======================================

                        // ECG LINE

                        // ======================================
                        lineBarsData: [
                          LineChartBarData(
                            spots: ecgSpots,

                            // ECG ไม่ใช้ curve
                            isCurved: false,

                            barWidth: 1.2,

                            dotData: const FlDotData(show: false),

                            belowBarData: BarAreaData(show: false),
                          ),

                          // ======================================================

                          // R-PEAK RED CIRCLES

                          // ======================================================
                          LineChartBarData(
                            spots: rPeakSpots,

                            // Don't draw a line between R-Peaks
                            barWidth: 0,

                            color: Colors.transparent,

                            isCurved: false,

                            dotData: FlDotData(
                              show: true,

                              getDotPainter: (spot, percent, barData, index) {
                                return FlDotCirclePainter(
                                  radius: 3,

                                  color: Colors.red,

                                  strokeWidth: 1,

                                  strokeColor: Colors.white,
                                );
                              },
                            ),

                            belowBarData: BarAreaData(show: false),
                          ),
                        ],
                      ),

                      // ปิด animation สำหรับ real-time ECG
                      duration: Duration.zero,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ==================================================

          // HR + RR

          // ==================================================
          Row(
            children: [
              Expanded(
                child: _valueCard(
                  'อัตราการเต้นหัวใจ',

                  currentHR,

                  Icons.favorite,
                ),
              ),

              Expanded(
                child: _valueCard(
                  'RR Interval',

                  currentRR,

                  Icons.monitor_heart,
                ),
              ),
            ],
          ),

          // ==================================================

          // RECORDING

          // ==================================================
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),

              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,

                children: [
                  const Text(
                    'รอบการวัด 05:00',

                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),

                  const SizedBox(height: 8),

                  Text(
                    '${_clock(elapsed)} / 05:00'
                    '     '
                    '$_sessionSamples ตัวอย่าง',
                  ),

                  const SizedBox(height: 10),

                  LinearProgressIndicator(value: progress),

                  const SizedBox(height: 12),

                  Row(
                    children: [
                      // --------------------------------------

                      // START

                      // --------------------------------------
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _connected && !_recording
                              ? _startSession
                              : null,

                          icon: const Icon(Icons.play_arrow),

                          label: const Text('เริ่มบันทึก'),
                        ),
                      ),

                      const SizedBox(width: 10),

                      // --------------------------------------

                      // STOP

                      // --------------------------------------
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _recording
                              ? () => _endSession(completed: false)
                              : null,

                          icon: const Icon(Icons.stop),

                          label: const Text('หยุด'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // ==========================================================
          // HRV ANALYSIS DASHBOARD
          // ==========================================================
          if (_history.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 24, 8, 12),
              child: Text(
                'ผลการวิเคราะห์ HRV',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
            ),

            Builder(
              builder: (context) {
                // ใช้ผลการวัดรอบล่าสุด
                final Map<String, dynamic> item = Map<String, dynamic>.from(
                  _history.first,
                );

                final bool completed = item['completed'] as bool? ?? false;

                return Card(
                  elevation: 2,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // ==================================================
                        // HEADER
                        // ==================================================

                        const Row(
                          children: [
                            Icon(
                              Icons.monitor_heart,
                              color: Color(0xFF1565C0),
                              size: 30,
                            ),

                            SizedBox(width: 10),

                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'HRV SUMMARY',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1.2,
                                      color: Color(0xFF1976D2),
                                    ),
                                  ),

                                  SizedBox(height: 2),

                                  Text(
                                    'Time-domain HRV',
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 18),

                        // ==================================================
                        // MEAN RR
                        // ==================================================
                        _hrvResultRow(
                          title: 'Mean RR',
                          value: '${_metric(item['meanRR'])} ms',
                        ),

                        const Divider(height: 1),

                        // ==================================================
                        // MEAN HR
                        // ==================================================
                        _hrvResultRow(
                          title: 'Mean HR',
                          value: '${_metric(item['meanHr'])} bpm',
                        ),

                        const Divider(height: 1),

                        // ==================================================
                        // SDNN
                        // ==================================================
                        _hrvResultRow(
                          title: 'SDNN',
                          value: '${_metric(item['sdnn'])} ms',
                        ),

                        const Divider(height: 1),

                        // ==================================================
                        // RMSSD
                        // ==================================================
                        _hrvResultRow(
                          title: 'RMSSD',
                          value: '${_metric(item['rmssd'])} ms',
                        ),

                        const Divider(height: 1),

                        // ==================================================
                        // SDSD
                        // ==================================================
                        _hrvResultRow(
                          title: 'SDSD',
                          value: '${_metric(item['sdsd'])} ms',
                        ),

                        const Divider(height: 1),

                        // ==================================================
                        // VALID RR
                        // ==================================================
                        _hrvResultRow(
                          title: 'Valid RR',
                          value: '${item['rrCount'] ?? 0} ค่า',
                        ),

                        const Divider(height: 1),

                        // ==================================================
                        // DURATION
                        // ==================================================
                        _hrvResultRow(
                          title: 'Duration',
                          value: completed ? '05:00 min' : 'ไม่ครบ 5 นาที',
                        ),

                        const SizedBox(height: 16),

                        // ==================================================
                        // INFORMATION
                        // ==================================================
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF4F8FD),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFFD8E6F5)),
                          ),
                          child: const Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.info_outline,
                                size: 20,
                                color: Color(0xFF1565C0),
                              ),

                              SizedBox(width: 8),

                              Expanded(
                                child: Text(
                                  'ค่าความแปรปรวนของอัตราการเต้นของหัวใจ '
                                  'คำนวณจาก RR interval ที่ตรวจจับจาก '
                                  'R-peak ของสัญญาณ ECG',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.black54,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
          // ==================================================

          // RESULTS TITLE

          // ==================================================
          const Padding(
            padding: EdgeInsets.fromLTRB(8, 18, 8, 8),

            child: Text(
              'ผลการวัดทุก 5 นาที',

              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),

          // ==================================================

          // HISTORY

          // ==================================================
          for (final item in _history)
            Card(
              child: ListTile(
                // ------------------------------------------

                // DATE

                // ------------------------------------------
                title: Text(
                  '${DateTime.parse(item['start'] as String).toLocal()}'
                          .substring(0, 16) +
                      ((item['completed'] as bool)
                          ? '  •  ครบ 5 นาที'
                          : '  •  ไม่ครบ 5 นาที'),
                ),

                // ------------------------------------------

                // HRV

                // ------------------------------------------
                subtitle: Text(
                  'Mean HR '
                  '${_metric(item['meanHr'], digits: 1)} bpm\n'
                  'Mean RR '
                  '${_metric(item['meanRR'], digits: 1)} ms\n'
                  'SDNN '
                  '${_metric(item['sdnn'], digits: 1)} ms   '
                  'RMSSD '
                  '${_metric(item['rmssd'], digits: 1)} ms\n'
                  'SDSD '
                  '${_metric(item['sdsd'], digits: 1)} ms\n'
                  'Valid RR '
                  '${item['rrCount'] ?? 0} ค่า   '
                  'Pairs '
                  '${item['rrPairCount'] ?? 0}\n'
                  'ECG '
                  '${item['samples']} samples',
                ),

                // ------------------------------------------

                // SHARE

                // ------------------------------------------
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PopupMenuButton<String>(
                      tooltip: 'ส่งออกข้อมูล',
                      icon: const Icon(Icons.download),

                      onSelected: (String value) {
                        if (value == 'full') {
                          _share(item);
                        } else if (value == 'kubios') {
                          _shareKubios(item);
                        } else if (value == 'raw') {
                          _shareRaw(item);
                        }
                      },

                      itemBuilder: (BuildContext context) {
                        return const [
                          PopupMenuItem<String>(
                            value: 'full',
                            child: Row(
                              children: [
                                Icon(Icons.table_chart_outlined),
                                SizedBox(width: 10),
                                Text('Full CSV'),
                              ],
                            ),
                          ),
                          PopupMenuItem<String>(
                            value: 'kubios',
                            child: Row(
                              children: [
                                Icon(Icons.monitor_heart_outlined),
                                SizedBox(width: 10),
                                Text('Kubios RR CSV'),
                              ],
                            ),
                          ),
                          PopupMenuItem<String>(
                            value: 'raw',
                            child: Row(
                              children: [
                                Icon(Icons.show_chart),
                                SizedBox(width: 10),
                                Text('Raw ECG CSV'),
                              ],
                            ),
                          ),
                        ];
                      },
                    ),
                    IconButton(
                      tooltip: 'ลบประวัติ',
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: () => _deleteHistoryItem(item),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ==========================================================

  // VALUE CARD

  // ==========================================================

  Widget _valueCard(String label, String value, IconData icon) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),

        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,

          children: [
            Icon(icon, color: const Color(0xff1261d0)),

            const SizedBox(height: 8),

            Text(label, style: const TextStyle(fontSize: 12)),

            Text(
              value,

              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  LineChartBarData sinLine(List<FlSpot> points) {
    return LineChartBarData(
      spots: points,

      dotData: const FlDotData(show: false),

      barWidth: 4,

      isCurved: false,
    );
  }

  // ==========================================================
  // HRV RESULT ROW
  // ==========================================================

  Widget _hrvResultRow({required String title, required String value}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 14, color: Colors.black87),
            ),
          ),

          const SizedBox(width: 12),

          Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: Color(0xFF172B4D),
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================

  // DISPOSE

  // ==========================================================

  @override
  void dispose() {
    _uiTimer?.cancel();

    _scanSub?.cancel();

    _ecgSub?.cancel();

    _connectionSub?.cancel();

    _sink?.close();

    _device?.disconnect();

    super.dispose();
  }
}
