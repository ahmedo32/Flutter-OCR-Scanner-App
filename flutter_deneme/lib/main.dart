import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'theme/theme_provider.dart';
import 'services/db_helper.dart';
import 'pages/home_page.dart';
import 'pages/camera_page.dart';
import 'pages/result_page.dart';
import 'pages/records_page.dart';
import 'pages/settings_page.dart';
import 'services/notification_service.dart';

/// A single, global instance of the notifications plugin
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.init();
  //Initialize your SQLite (or whatever) DB
  await DBHelper.database;

  //Initialize local notifications
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosSettings = DarwinInitializationSettings();
  const initSettings = InitializationSettings(
    android: androidSettings,
    iOS: iosSettings,
  );
  await flutterLocalNotificationsPlugin.initialize(initSettings);

  //Run the app, hooking up your ThemeProvider
  runApp(
    ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProv = Provider.of<ThemeProvider>(context);

    return MaterialApp(
      title: 'OCR Scanner App',
      debugShowCheckedModeBanner: false,

      //Localization support
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en'), // English
        Locale('tr'), // Turkish
      ],

      //Theme setup
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeMode: themeProv.themeMode,

      //Routes
      initialRoute: '/',
      routes: {
        '/':        (_) => const HomePage(),
        '/camera':  (_) => const CameraPage(),
        '/result':  (_) => const ResultPage(),
        '/records': (_) => const RecordsPage(),
        '/settings':(_) => const SettingsPage(),
      },
    );
  }
}
