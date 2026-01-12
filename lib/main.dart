import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:pdfx/pdfx.dart';
import 'package:photo_view/photo_view.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path_lib;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_animations/flutter_map_animations.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:get/get.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as path_package;
import 'dart:convert';
import 'package:crypto/crypto.dart';

// ==============================================
// DATABASE HELPER FOR SQLITE
// ==============================================

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;

  static Database? _database;

  DatabaseHelper._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final path = path_package.join(documentsDirectory.path, 'paperlink.db');

    return await openDatabase(
      path,
      version: 2,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    // Users table
    await db.execute('''
      CREATE TABLE users(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        email TEXT UNIQUE NOT NULL,
        password TEXT NOT NULL,
        fullName TEXT NOT NULL,
        studentId TEXT UNIQUE NOT NULL,
        phoneNumber TEXT,
        profilePicture TEXT,
        createdAt TEXT NOT NULL,
        isLoggedIn INTEGER DEFAULT 0
      )
    ''');

    // User papers table
    await db.execute('''
      CREATE TABLE user_papers(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        userId INTEGER NOT NULL,
        paperId TEXT NOT NULL,
        title TEXT NOT NULL,
        subject TEXT NOT NULL,
        status TEXT NOT NULL,
        filePath TEXT,
        fileType TEXT,
        uploadedAt TEXT NOT NULL,
        FOREIGN KEY (userId) REFERENCES users (id) ON DELETE CASCADE
      )
    ''');

    // Create indexes
    await db.execute('CREATE INDEX idx_user_id ON user_papers(userId)');
    await db.execute('CREATE INDEX idx_email ON users(email)');
    await db.execute('CREATE INDEX idx_student_id ON users(studentId)');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS user_papers(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          userId INTEGER NOT NULL,
          paperId TEXT NOT NULL,
          title TEXT NOT NULL,
          subject TEXT NOT NULL,
          status TEXT NOT NULL,
          filePath TEXT,
          fileType TEXT,
          uploadedAt TEXT NOT NULL,
          FOREIGN KEY (userId) REFERENCES users (id) ON DELETE CASCADE
        )
      ''');
    }
  }

  // User operations
  Future<int> insertUser(Map<String, dynamic> user) async {
    final db = await database;
    return await db.insert('users', user);
  }

  Future<Map<String, dynamic>?> getUserByEmail(String email) async {
    final db = await database;
    final List<Map<String, dynamic>> results = await db.query(
      'users',
      where: 'email = ?',
      whereArgs: [email],
    );
    return results.isNotEmpty ? results.first : null;
  }

  Future<Map<String, dynamic>?> getUserByStudentId(String studentId) async {
    final db = await database;
    final List<Map<String, dynamic>> results = await db.query(
      'users',
      where: 'studentId = ?',
      whereArgs: [studentId],
    );
    return results.isNotEmpty ? results.first : null;
  }

  Future<Map<String, dynamic>?> getLoggedInUser() async {
    final db = await database;
    final List<Map<String, dynamic>> results = await db.query(
      'users',
      where: 'isLoggedIn = ?',
      whereArgs: [1],
    );
    return results.isNotEmpty ? results.first : null;
  }

  Future<void> updateUserLoginStatus(int userId, bool isLoggedIn) async {
    final db = await database;
    await db.update(
      'users',
      {'isLoggedIn': isLoggedIn ? 1 : 0},
      where: 'id = ?',
      whereArgs: [userId],
    );
  }

  Future<void> updateUserProfile(
    int userId,
    Map<String, dynamic> updates,
  ) async {
    final db = await database;
    await db.update('users', updates, where: 'id = ?', whereArgs: [userId]);
  }

  Future<void> logoutAllUsers() async {
    final db = await database;
    await db.update('users', {'isLoggedIn': 0});
  }

  // Paper operations
  Future<int> insertUserPaper(Map<String, dynamic> paper) async {
    final db = await database;
    return await db.insert('user_papers', paper);
  }

  Future<List<Map<String, dynamic>>> getUserPapers(int userId) async {
    final db = await database;
    return await db.query(
      'user_papers',
      where: 'userId = ?',
      whereArgs: [userId],
      orderBy: 'uploadedAt DESC',
    );
  }

  Future<void> deleteUserPaper(int paperId) async {
    final db = await database;
    await db.delete('user_papers', where: 'id = ?', whereArgs: [paperId]);
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
  }
}

// ==============================================
// AUTHENTICATION MANAGER
// ==============================================

class AuthManager {
  static final AuthManager _instance = AuthManager._internal();
  factory AuthManager() => _instance;

  final DatabaseHelper _dbHelper = DatabaseHelper();
  Map<String, dynamic>? _currentUser;

  AuthManager._internal();

  // Hash password using SHA-256
  String _hashPassword(String password) {
    final bytes = utf8.encode(password);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  // Register new user
  Future<Map<String, dynamic>> registerUser({
    required String email,
    required String password,
    required String fullName,
    required String studentId,
    String? phoneNumber,
    String? profilePicturePath,
  }) async {
    // Check if email already exists
    final existingUser = await _dbHelper.getUserByEmail(email);
    if (existingUser != null) {
      throw Exception('Email already registered');
    }

    // Check if student ID already exists
    final existingStudent = await _dbHelper.getUserByStudentId(studentId);
    if (existingStudent != null) {
      throw Exception('Student ID already registered');
    }

    // Create new user
    final newUser = {
      'email': email,
      'password': _hashPassword(password),
      'fullName': fullName,
      'studentId': studentId,
      'phoneNumber': phoneNumber ?? '',
      'profilePicture': profilePicturePath ?? '',
      'createdAt': DateTime.now().toIso8601String(),
      'isLoggedIn': 0,
    };

    final userId = await _dbHelper.insertUser(newUser);
    newUser['id'] = userId;

    return newUser;
  }

  // Login user
  Future<Map<String, dynamic>> loginUser({
    required String email,
    required String password,
  }) async {
    final user = await _dbHelper.getUserByEmail(email);

    if (user == null) {
      throw Exception('User not found');
    }

    final hashedPassword = _hashPassword(password);
    if (user['password'] != hashedPassword) {
      throw Exception('Invalid password');
    }

    // Logout all users first
    await _dbHelper.logoutAllUsers();

    // Set current user as logged in
    await _dbHelper.updateUserLoginStatus(user['id'], true);

    _currentUser = user;
    return user;
  }

  // Get current user
  Future<Map<String, dynamic>?> getCurrentUser() async {
    if (_currentUser != null) return _currentUser;

    _currentUser = await _dbHelper.getLoggedInUser();
    return _currentUser;
  }

  // Logout user
  Future<void> logout() async {
    if (_currentUser != null) {
      await _dbHelper.updateUserLoginStatus(_currentUser!['id'], false);
    }
    _currentUser = null;
  }

  // Update user profile
  Future<void> updateProfile({
    required int userId,
    String? fullName,
    String? phoneNumber,
    String? profilePicturePath,
  }) async {
    final updates = <String, dynamic>{};

    if (fullName != null) updates['fullName'] = fullName;
    if (phoneNumber != null) updates['phoneNumber'] = phoneNumber;
    if (profilePicturePath != null)
      updates['profilePicture'] = profilePicturePath;

    if (updates.isNotEmpty) {
      await _dbHelper.updateUserProfile(userId, updates);

      // Update current user in memory
      if (_currentUser != null && _currentUser!['id'] == userId) {
        _currentUser = {..._currentUser!, ...updates};
      }
    }
  }

  // Check if user is logged in
  Future<bool> isLoggedIn() async {
    final user = await getCurrentUser();
    return user != null;
  }
}

// ==============================================
// FILE STORAGE HELPER
// ==============================================

class FileStorageHelper {
  static Future<String> getProfilePicturesDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final profilePicsDir = Directory('${appDir.path}/profile_pictures');

    if (!await profilePicsDir.exists()) {
      await profilePicsDir.create(recursive: true);
    }

    return profilePicsDir.path;
  }

  static Future<String> saveProfilePicture(
    File imageFile,
    String userId,
  ) async {
    final dir = await getProfilePicturesDirectory();
    final extension = path_lib.extension(imageFile.path);
    final newPath = '$dir/profile_$userId$extension';

    await imageFile.copy(newPath);
    return newPath;
  }

  static Future<void> deleteProfilePicture(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

// ==============================================
// MAIN APP
// ==============================================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarBrightness: Brightness.dark,
      statusBarIconBrightness: Brightness.dark,
    ),
  );

  // Initialize database
  await DatabaseHelper().database;

  runApp(const PaperLinkApp());
}

class PaperLinkApp extends StatelessWidget {
  const PaperLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PaperLink',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
        fontFamily: 'Roboto',
        appBarTheme: const AppBarTheme(
          systemOverlayStyle: SystemUiOverlayStyle.light,
          elevation: 0,
        ),
      ),
      debugShowCheckedModeBanner: false,
      home: const SplashScreen(),
    );
  }
}

// ==============================================
// SPLASH SCREEN
// ==============================================

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;
  final AuthManager _authManager = AuthManager();

  @override
  void initState() {
    super.initState();

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: const Interval(0.0, 0.8, curve: Curves.easeIn),
      ),
    );

    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: const Interval(0.3, 1.0, curve: Curves.elasticOut),
      ),
    );

    _animationController.forward();

    // Check if user is logged in
    _checkLoginStatus();
  }

  Future<void> _checkLoginStatus() async {
    await Future.delayed(const Duration(seconds: 2));

    final isLoggedIn = await _authManager.isLoggedIn();

    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) =>
            isLoggedIn ? const StudentHomePage() : const WelcomePage(),
        transitionsBuilder: (_, animation, __, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 500),
      ),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1565C0),
      body: Center(
        child: AnimatedBuilder(
          animation: _animationController,
          builder: (context, child) {
            return Opacity(
              opacity: _fadeAnimation.value,
              child: Transform.scale(
                scale: _scaleAnimation.value,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(30),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.2),
                            blurRadius: 20,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.school,
                        size: 70,
                        color: Color(0xFF1565C0),
                      ),
                    ),
                    const SizedBox(height: 30),
                    Text(
                      'PaperLink',
                      style: TextStyle(
                        fontSize: 42,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        shadows: [
                          Shadow(
                            blurRadius: 10,
                            color: Colors.black.withOpacity(0.3),
                            offset: const Offset(2, 2),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Educational Portal',
                      style: TextStyle(
                        fontSize: 18,
                        color: Colors.white.withOpacity(0.9),
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                    const SizedBox(height: 40),
                    SizedBox(
                      width: 40,
                      height: 40,
                      child: CircularProgressIndicator(
                        value: _animationController.value,
                        strokeWidth: 3,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Colors.white.withOpacity(0.8),
                        ),
                        backgroundColor: Colors.white.withOpacity(0.2),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Loading...',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.white.withOpacity(0.7),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ==============================================
// WELCOME PAGE
// ==============================================

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1565C0), Color(0xFF4A148C)],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.school, size: 100, color: Colors.white),
                const SizedBox(height: 20),
                const Text(
                  'PaperLink',
                  style: TextStyle(
                    fontSize: 48,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    shadows: [
                      Shadow(
                        blurRadius: 4,
                        color: Colors.black26,
                        offset: Offset(2, 2),
                      ),
                    ],
                  ),
                ),
                const Text(
                  'Educational Portal',
                  style: TextStyle(fontSize: 18, color: Colors.white70),
                ),
                const SizedBox(height: 50),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 300),
                  child: ElevatedButton(
                    onPressed: () => _navigateToAdmin(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.blue[800],
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 4,
                      shadowColor: Colors.black26,
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.admin_panel_settings),
                        SizedBox(width: 10),
                        Text(
                          'Admin Login',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 300),
                  child: ElevatedButton(
                    onPressed: () => _navigateToStudentAuth(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.blue[800],
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 4,
                      shadowColor: Colors.black26,
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.person),
                        SizedBox(width: 10),
                        Text(
                          'Student Access',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 40),
                const Text(
                  'Educational portal',
                  style: TextStyle(fontSize: 14, color: Colors.white70),
                ),
                const Text(
                  'Manage Student Papers',
                  style: TextStyle(fontSize: 12, color: Colors.white60),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _navigateToAdmin(BuildContext context) {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const AdminLoginPage(),
        transitionsBuilder: (_, animation, __, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 200),
      ),
    );
  }

  void _navigateToStudentAuth(BuildContext context) {
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const StudentAuthPage(),
        transitionsBuilder: (_, animation, __, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 200),
      ),
    );
  }
}

// ==============================================
// STUDENT AUTHENTICATION PAGE (REGISTER/LOGIN)
// ==============================================

class StudentAuthPage extends StatefulWidget {
  const StudentAuthPage({super.key});

  @override
  State<StudentAuthPage> createState() => _StudentAuthPageState();
}

class _StudentAuthPageState extends State<StudentAuthPage> {
  final AuthManager _authManager = AuthManager();
  final PageController _pageController = PageController();
  int _currentPage = 0;

  // Login controllers
  final TextEditingController _loginEmailController = TextEditingController();
  final TextEditingController _loginPasswordController =
      TextEditingController();
  final ValueNotifier<bool> _loginPasswordVisible = ValueNotifier(false);
  final ValueNotifier<bool> _loginLoading = ValueNotifier(false);

  // Register controllers
  final TextEditingController _registerEmailController =
      TextEditingController();
  final TextEditingController _registerPasswordController =
      TextEditingController();
  final TextEditingController _registerConfirmPasswordController =
      TextEditingController();
  final TextEditingController _registerFullNameController =
      TextEditingController();
  final TextEditingController _registerStudentIdController =
      TextEditingController();
  final TextEditingController _registerPhoneController =
      TextEditingController();
  final ValueNotifier<bool> _registerPasswordVisible = ValueNotifier(false);
  final ValueNotifier<bool> _registerConfirmPasswordVisible = ValueNotifier(
    false,
  );
  final ValueNotifier<bool> _registerLoading = ValueNotifier(false);

  // Profile picture
  File? _profilePicture;
  final ImagePicker _picker = ImagePicker();

  @override
  void dispose() {
    _pageController.dispose();
    _loginEmailController.dispose();
    _loginPasswordController.dispose();
    _loginPasswordVisible.dispose();
    _loginLoading.dispose();
    _registerEmailController.dispose();
    _registerPasswordController.dispose();
    _registerConfirmPasswordController.dispose();
    _registerFullNameController.dispose();
    _registerStudentIdController.dispose();
    _registerPhoneController.dispose();
    _registerPasswordVisible.dispose();
    _registerConfirmPasswordVisible.dispose();
    _registerLoading.dispose();
    super.dispose();
  }

  Future<void> _pickProfilePicture() async {
    final XFile? file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );

    if (file != null) {
      setState(() {
        _profilePicture = File(file.path);
      });
    }
  }

  Future<void> _takeProfilePicture() async {
    final XFile? file = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
    );

    if (file != null) {
      setState(() {
        _profilePicture = File(file.path);
      });
    }
  }

  Future<void> _login() async {
    final email = _loginEmailController.text.trim();
    final password = _loginPasswordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please fill in all fields'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    _loginLoading.value = true;

    try {
      await _authManager.loginUser(email: email, password: password);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Login successful!'),
          duration: Duration(seconds: 2),
          backgroundColor: Colors.green,
        ),
      );

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const StudentHomePage()),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Login failed: $e'),
          duration: const Duration(seconds: 3),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      _loginLoading.value = false;
    }
  }

  Future<void> _register() async {
    final email = _registerEmailController.text.trim();
    final password = _registerPasswordController.text.trim();
    final confirmPassword = _registerConfirmPasswordController.text.trim();
    final fullName = _registerFullNameController.text.trim();
    final studentId = _registerStudentIdController.text.trim();
    final phone = _registerPhoneController.text.trim();

    // Validation
    if (email.isEmpty ||
        password.isEmpty ||
        confirmPassword.isEmpty ||
        fullName.isEmpty ||
        studentId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please fill in all required fields'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(email)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid email address'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    if (password.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Password must be at least 6 characters'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    if (password != confirmPassword) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Passwords do not match'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    _registerLoading.value = true;

    try {
      String? profilePicturePath;
      if (_profilePicture != null) {
        profilePicturePath = await FileStorageHelper.saveProfilePicture(
          _profilePicture!,
          studentId,
        );
      }

      await _authManager.registerUser(
        email: email,
        password: password,
        fullName: fullName,
        studentId: studentId,
        phoneNumber: phone.isNotEmpty ? phone : null,
        profilePicturePath: profilePicturePath,
      );

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Registration successful! Please login'),
          duration: Duration(seconds: 3),
          backgroundColor: Colors.green,
        ),
      );

      // Switch to login page
      _pageController.animateToPage(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
      setState(() {
        _currentPage = 0;
      });

      // Clear form
      _registerEmailController.clear();
      _registerPasswordController.clear();
      _registerConfirmPasswordController.clear();
      _registerFullNameController.clear();
      _registerStudentIdController.clear();
      _registerPhoneController.clear();
      _profilePicture = null;
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Registration failed: $e'),
          duration: const Duration(seconds: 3),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      _registerLoading.value = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const WelcomePage()),
          ),
        ),
        title: const Text('Student Authentication'),
      ),
      body: PageView(
        controller: _pageController,
        onPageChanged: (page) {
          setState(() {
            _currentPage = page;
          });
        },
        children: [
          // Login Page
          _buildLoginPage(),

          // Register Page
          _buildRegisterPage(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentPage,
        onTap: (index) {
          _pageController.animateToPage(
            index,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.login), label: 'Login'),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_add),
            label: 'Register',
          ),
        ],
      ),
    );
  }

  Widget _buildLoginPage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          const Center(child: Icon(Icons.school, size: 80, color: Colors.blue)),
          const SizedBox(height: 20),
          const Center(
            child: Text(
              'Student Login',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 10),
          const Center(
            child: Text(
              'Login to access your papers and exercises',
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),
          ),
          const SizedBox(height: 40),

          TextFormField(
            controller: _loginEmailController,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
              labelText: 'Email',
              prefixIcon: const Icon(Icons.email),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 20),

          ValueListenableBuilder<bool>(
            valueListenable: _loginPasswordVisible,
            builder: (context, isVisible, child) {
              return TextFormField(
                controller: _loginPasswordController,
                obscureText: !isVisible,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock),
                  suffixIcon: IconButton(
                    icon: Icon(
                      isVisible ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () {
                      _loginPasswordVisible.value =
                          !_loginPasswordVisible.value;
                    },
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              );
            },
          ),

          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () {
                // TODO: Implement forgot password
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Forgot password feature coming soon'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              child: const Text('Forgot Password?'),
            ),
          ),

          const SizedBox(height: 30),

          ValueListenableBuilder<bool>(
            valueListenable: _loginLoading,
            builder: (context, isLoading, child) {
              return SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: isLoading ? null : _login,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'Login',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              );
            },
          ),

          const SizedBox(height: 20),
          const Divider(),
          const SizedBox(height: 20),

          Center(
            child: TextButton(
              onPressed: () {
                _pageController.animateToPage(
                  1,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                );
              },
              child: const Text('Don\'t have an account? Register here'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRegisterPage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          const Center(
            child: Icon(Icons.person_add, size: 80, color: Colors.blue),
          ),
          const SizedBox(height: 20),
          const Center(
            child: Text(
              'Student Registration',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 10),
          const Center(
            child: Text(
              'Create your account to start using PaperLink',
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),
          ),
          const SizedBox(height: 40),

          // Profile Picture Section
          Center(
            child: Column(
              children: [
                Stack(
                  children: [
                    CircleAvatar(
                      radius: 60,
                      backgroundColor: Colors.grey[200],
                      backgroundImage: _profilePicture != null
                          ? FileImage(_profilePicture!)
                          : null,
                      child: _profilePicture == null
                          ? const Icon(
                              Icons.person,
                              size: 50,
                              color: Colors.grey,
                            )
                          : null,
                    ),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.blue,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                        ),
                        child: IconButton(
                          icon: const Icon(
                            Icons.camera_alt,
                            color: Colors.white,
                            size: 20,
                          ),
                          onPressed: () {
                            showModalBottomSheet(
                              context: context,
                              shape: const RoundedRectangleBorder(
                                borderRadius: BorderRadius.vertical(
                                  top: Radius.circular(20),
                                ),
                              ),
                              builder: (context) {
                                return Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    ListTile(
                                      leading: const Icon(Icons.photo_library),
                                      title: const Text('Choose from Gallery'),
                                      onTap: () {
                                        Navigator.pop(context);
                                        _pickProfilePicture();
                                      },
                                    ),
                                    ListTile(
                                      leading: const Icon(Icons.camera_alt),
                                      title: const Text('Take Photo'),
                                      onTap: () {
                                        Navigator.pop(context);
                                        _takeProfilePicture();
                                      },
                                    ),
                                    if (_profilePicture != null)
                                      ListTile(
                                        leading: const Icon(
                                          Icons.delete,
                                          color: Colors.red,
                                        ),
                                        title: const Text(
                                          'Remove Photo',
                                          style: TextStyle(color: Colors.red),
                                        ),
                                        onTap: () {
                                          Navigator.pop(context);
                                          setState(() {
                                            _profilePicture = null;
                                          });
                                        },
                                      ),
                                  ],
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'Profile Picture (Optional)',
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ),
          ),

          const SizedBox(height: 30),

          TextFormField(
            controller: _registerFullNameController,
            decoration: InputDecoration(
              labelText: 'Full Name *',
              prefixIcon: const Icon(Icons.person),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 20),

          TextFormField(
            controller: _registerStudentIdController,
            decoration: InputDecoration(
              labelText: 'Student ID *',
              prefixIcon: const Icon(Icons.badge),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 20),

          TextFormField(
            controller: _registerEmailController,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
              labelText: 'Email *',
              prefixIcon: const Icon(Icons.email),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 20),

          ValueListenableBuilder<bool>(
            valueListenable: _registerPasswordVisible,
            builder: (context, isVisible, child) {
              return TextFormField(
                controller: _registerPasswordController,
                obscureText: !isVisible,
                decoration: InputDecoration(
                  labelText: 'Password *',
                  prefixIcon: const Icon(Icons.lock),
                  suffixIcon: IconButton(
                    icon: Icon(
                      isVisible ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () {
                      _registerPasswordVisible.value =
                          !_registerPasswordVisible.value;
                    },
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 20),

          ValueListenableBuilder<bool>(
            valueListenable: _registerConfirmPasswordVisible,
            builder: (context, isVisible, child) {
              return TextFormField(
                controller: _registerConfirmPasswordController,
                obscureText: !isVisible,
                decoration: InputDecoration(
                  labelText: 'Confirm Password *',
                  prefixIcon: const Icon(Icons.lock),
                  suffixIcon: IconButton(
                    icon: Icon(
                      isVisible ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () {
                      _registerConfirmPasswordVisible.value =
                          !_registerConfirmPasswordVisible.value;
                    },
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 20),

          TextFormField(
            controller: _registerPhoneController,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              labelText: 'Phone Number (Optional)',
              prefixIcon: const Icon(Icons.phone),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),

          const SizedBox(height: 30),

          ValueListenableBuilder<bool>(
            valueListenable: _registerLoading,
            builder: (context, isLoading, child) {
              return SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: isLoading ? null : _register,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'Register',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              );
            },
          ),

          const SizedBox(height: 20),
          const Divider(),
          const SizedBox(height: 20),

          Center(
            child: TextButton(
              onPressed: () {
                _pageController.animateToPage(
                  0,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                );
              },
              child: const Text('Already have an account? Login here'),
            ),
          ),
        ],
      ),
    );
  }
}

// ==============================================
// STUDENT PROFILE PAGE
// ==============================================

class StudentProfilePage extends StatefulWidget {
  const StudentProfilePage({super.key});

  @override
  State<StudentProfilePage> createState() => _StudentProfilePageState();
}

class _StudentProfilePageState extends State<StudentProfilePage> {
  final AuthManager _authManager = AuthManager();
  final DatabaseHelper _dbHelper = DatabaseHelper();
  Map<String, dynamic>? _user;
  List<Map<String, dynamic>> _userPapers = [];
  bool _isLoading = true;

  // Profile editing
  final TextEditingController _fullNameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  File? _newProfilePicture;
  final ImagePicker _picker = ImagePicker();
  bool _isEditing = false;

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  Future<void> _loadUserData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      _user = await _authManager.getCurrentUser();
      if (_user != null) {
        _fullNameController.text = _user!['fullName'];
        _phoneController.text = _user!['phoneNumber'] ?? '';

        // Load user papers
        _userPapers = await _dbHelper.getUserPapers(_user!['id']);
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error loading profile: $e'),
          duration: const Duration(seconds: 3),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _pickNewProfilePicture() async {
    final XFile? file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );

    if (file != null) {
      setState(() {
        _newProfilePicture = File(file.path);
      });
    }
  }

  Future<void> _takeNewProfilePicture() async {
    final XFile? file = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
    );

    if (file != null) {
      setState(() {
        _newProfilePicture = File(file.path);
      });
    }
  }

  Future<void> _saveProfileChanges() async {
    if (_user == null) return;

    try {
      String? profilePicturePath;

      // Save new profile picture if selected
      if (_newProfilePicture != null) {
        // Delete old profile picture if exists
        if (_user!['profilePicture'] != null &&
            _user!['profilePicture'].isNotEmpty) {
          await FileStorageHelper.deleteProfilePicture(
            _user!['profilePicture'],
          );
        }

        profilePicturePath = await FileStorageHelper.saveProfilePicture(
          _newProfilePicture!,
          _user!['studentId'],
        );
      }

      await _authManager.updateProfile(
        userId: _user!['id'],
        fullName: _fullNameController.text.trim(),
        phoneNumber: _phoneController.text.trim(),
        profilePicturePath: profilePicturePath,
      );

      // Reload user data
      await _loadUserData();

      setState(() {
        _isEditing = false;
        _newProfilePicture = null;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Profile updated successfully!'),
          duration: Duration(seconds: 2),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error updating profile: $e'),
          duration: const Duration(seconds: 3),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _logout() async {
    try {
      await _authManager.logout();

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const WelcomePage()),
        (route) => false,
      );

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Logged out successfully'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error logging out: $e'),
          duration: const Duration(seconds: 3),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Profile')),
        body: const Center(child: Text('User not found. Please login again.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Profile'),
        actions: [
          if (!_isEditing)
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () {
                setState(() {
                  _isEditing = true;
                });
              },
            ),
          if (_isEditing)
            IconButton(
              icon: const Icon(Icons.save),
              onPressed: _saveProfileChanges,
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // Profile Picture
            Stack(
              children: [
                CircleAvatar(
                  radius: 70,
                  backgroundColor: Colors.grey[200],
                  backgroundImage: _newProfilePicture != null
                      ? FileImage(_newProfilePicture!)
                      : (_user!['profilePicture'] != null &&
                            _user!['profilePicture'].isNotEmpty)
                      ? FileImage(File(_user!['profilePicture']))
                      : null,
                  child:
                      (_newProfilePicture == null &&
                          (_user!['profilePicture'] == null ||
                              _user!['profilePicture'].isEmpty))
                      ? const Icon(Icons.person, size: 60, color: Colors.grey)
                      : null,
                ),
                if (_isEditing)
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.blue,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                      ),
                      child: IconButton(
                        icon: const Icon(
                          Icons.camera_alt,
                          color: Colors.white,
                          size: 20,
                        ),
                        onPressed: () {
                          showModalBottomSheet(
                            context: context,
                            shape: const RoundedRectangleBorder(
                              borderRadius: BorderRadius.vertical(
                                top: Radius.circular(20),
                              ),
                            ),
                            builder: (context) {
                              return Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ListTile(
                                    leading: const Icon(Icons.photo_library),
                                    title: const Text('Choose from Gallery'),
                                    onTap: () {
                                      Navigator.pop(context);
                                      _pickNewProfilePicture();
                                    },
                                  ),
                                  ListTile(
                                    leading: const Icon(Icons.camera_alt),
                                    title: const Text('Take Photo'),
                                    onTap: () {
                                      Navigator.pop(context);
                                      _takeNewProfilePicture();
                                    },
                                  ),
                                ],
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),

            const SizedBox(height: 20),

            // User Info
            if (!_isEditing)
              Column(
                children: [
                  Text(
                    _user!['fullName'],
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _user!['email'],
                    style: const TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'Student ID: ${_user!['studentId']}',
                    style: const TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                  if (_user!['phoneNumber'] != null &&
                      _user!['phoneNumber'].isNotEmpty)
                    Text(
                      'Phone: ${_user!['phoneNumber']}',
                      style: const TextStyle(fontSize: 16, color: Colors.grey),
                    ),
                  const SizedBox(height: 10),
                  Text(
                    'Member since: ${DateTime.parse(_user!['createdAt']).toLocal().toString().split(' ')[0]}',
                    style: const TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                ],
              )
            else
              Column(
                children: [
                  TextFormField(
                    controller: _fullNameController,
                    decoration: InputDecoration(
                      labelText: 'Full Name',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      labelText: 'Phone Number',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ],
              ),

            const SizedBox(height: 30),
            const Divider(),
            const SizedBox(height: 20),

            // My Papers Section
            const Text(
              'My Papers',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),

            _userPapers.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text(
                      'No papers submitted yet',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : Column(
                    children: _userPapers.map((paper) {
                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          leading: Icon(
                            paper['status'] == 'approved'
                                ? Icons.check_circle
                                : Icons.pending,
                            color: paper['status'] == 'approved'
                                ? Colors.green
                                : Colors.orange,
                          ),
                          title: Text(paper['title']),
                          subtitle: Text(
                            '${paper['subject']} • ${paper['status']} • ${DateTime.parse(paper['uploadedAt']).toLocal().toString().split(' ')[0]}',
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (paper['filePath'] != null)
                                IconButton(
                                  icon: const Icon(Icons.visibility, size: 20),
                                  onPressed: () {
                                    // TODO: Implement file viewer
                                  },
                                ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete,
                                  size: 20,
                                  color: Colors.red,
                                ),
                                onPressed: () async {
                                  await _dbHelper.deleteUserPaper(paper['id']);
                                  await _loadUserData();
                                },
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),

            const SizedBox(height: 30),

            // Logout Button
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _logout,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Logout',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ),

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

// ==============================================
// ADMIN LOGIN PAGE
// ==============================================

class AdminLoginPage extends StatefulWidget {
  const AdminLoginPage({super.key});

  @override
  State<AdminLoginPage> createState() => _AdminLoginPageState();
}

class _AdminLoginPageState extends State<AdminLoginPage> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final ValueNotifier<bool> _isPasswordVisible = ValueNotifier(false);
  final ValueNotifier<bool> _isLoading = ValueNotifier(false);
  final FocusNode _passwordFocusNode = FocusNode();

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _isPasswordVisible.dispose();
    _isLoading.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Admin Login'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),
            const Center(
              child: Icon(
                Icons.admin_panel_settings,
                size: 80,
                color: Colors.blue,
              ),
            ),
            const SizedBox(height: 20),
            const Center(
              child: Text(
                'Admin Portal',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 10),
            const Center(
              child: Text(
                'Password-based secure access',
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
            ),
            const SizedBox(height: 40),
            TextFormField(
              controller: _usernameController,
              textInputAction: TextInputAction.next,
              onFieldSubmitted: (_) => _passwordFocusNode.requestFocus(),
              decoration: InputDecoration(
                labelText: 'Admin Name',
                prefixIcon: const Icon(Icons.person),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 20),
            ValueListenableBuilder<bool>(
              valueListenable: _isPasswordVisible,
              builder: (context, isVisible, child) {
                return TextFormField(
                  controller: _passwordController,
                  focusNode: _passwordFocusNode,
                  obscureText: !isVisible,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _loginAsAdmin(),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock),
                    suffixIcon: IconButton(
                      icon: Icon(
                        isVisible ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () {
                        _isPasswordVisible.value = !_isPasswordVisible.value;
                      },
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () {
                  _showForgotPasswordDialog(context);
                },
                child: const Text('Forgot Password?'),
              ),
            ),
            const SizedBox(height: 30),
            ValueListenableBuilder<bool>(
              valueListenable: _isLoading,
              builder: (context, isLoading, child) {
                return SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: isLoading ? null : _loginAsAdmin,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            'Login',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                );
              },
            ),
            const SizedBox(height: 20),
            const Divider(),
            const SizedBox(height: 20),
            Center(
              child: TextButton(
                onPressed: () {
                  Navigator.pushReplacement(
                    context,
                    PageRouteBuilder(
                      pageBuilder: (_, __, ___) => const StudentAuthPage(),
                      transitionsBuilder: (_, animation, __, child) {
                        return SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(1, 0),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        );
                      },
                      transitionDuration: const Duration(milliseconds: 300),
                    ),
                  );
                },
                child: const Text('Switch to Student Access'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _loginAsAdmin() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (username.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter both username and password'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    // Check for correct credentials
    if (username != 'Fahdil' || password != 'Fahdil@1') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Invalid username or password'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    _isLoading.value = true;

    await Future.delayed(const Duration(milliseconds: 500));

    _isLoading.value = false;

    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const AdminHomePage(),
        transitionsBuilder: (_, animation, __, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  void _showForgotPasswordDialog(BuildContext context) {
    final emailController = TextEditingController();
    final focusNode = FocusNode();

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        return AlertDialog(
          title: const Text('Reset Password'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Enter your admin email to receive reset instructions',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: emailController,
                focusNode: focusNode,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Admin Email',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onFieldSubmitted: (_) {
                  _processPasswordReset(context, emailController.text.trim());
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                _processPasswordReset(context, emailController.text.trim());
              },
              child: const Text('Send Instructions'),
            ),
          ],
        );
      },
    ).then((_) {
      emailController.dispose();
      focusNode.dispose();
    });
  }

  void _processPasswordReset(BuildContext context, String email) {
    if (email.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter your email'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Password reset instructions sent to your email'),
        duration: Duration(seconds: 3),
      ),
    );
  }
}

// ==============================================
// MESSAGING SYSTEM (FROM ORIGINAL CODE)
// ==============================================

class Message {
  final String id;
  final String senderId;
  final String senderName;
  final String receiverId;
  final String text;
  final DateTime timestamp;
  final bool isRead;

  Message({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.receiverId,
    required this.text,
    required this.timestamp,
    this.isRead = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'senderId': senderId,
      'senderName': senderName,
      'receiverId': receiverId,
      'text': text,
      'timestamp': timestamp.toIso8601String(),
      'isRead': isRead,
    };
  }

  factory Message.fromMap(Map<String, dynamic> map) {
    return Message(
      id: map['id'],
      senderId: map['senderId'],
      senderName: map['senderName'],
      receiverId: map['receiverId'],
      text: map['text'],
      timestamp: DateTime.parse(map['timestamp']),
      isRead: map['isRead'] ?? false,
    );
  }
}

class MessageManager {
  static final MessageManager _instance = MessageManager._internal();

  factory MessageManager() {
    return _instance;
  }

  MessageManager._internal();

  // Store messages between admin and students
  final List<Message> _messages = [
    Message(
      id: '1',
      senderId: 'STU001',
      senderName: 'Student',
      receiverId: 'ADMIN',
      text: 'Hello Admin, when will my paper be reviewed?',
      timestamp: DateTime.now().subtract(const Duration(hours: 2)),
      isRead: true,
    ),
    Message(
      id: '2',
      senderId: 'ADMIN',
      senderName: 'Admin Fahdil',
      receiverId: 'STU001',
      text: 'Your paper is in the queue, will be reviewed within 24 hours.',
      timestamp: DateTime.now().subtract(const Duration(hours: 1, minutes: 55)),
      isRead: true,
    ),
    Message(
      id: '3',
      senderId: 'STU001',
      senderName: 'Student',
      receiverId: 'ADMIN',
      text: 'Thank you!',
      timestamp: DateTime.now().subtract(const Duration(hours: 1, minutes: 50)),
      isRead: true,
    ),
    Message(
      id: '4',
      senderId: 'STU2024001',
      senderName: 'John Doe',
      receiverId: 'ADMIN',
      text: 'Can I submit a revised version of my paper?',
      timestamp: DateTime.now().subtract(const Duration(days: 1)),
      isRead: true,
    ),
    Message(
      id: '5',
      senderId: 'ADMIN',
      senderName: 'Admin Fahdil',
      receiverId: 'STU2024001',
      text: 'Yes, you can submit a revised version anytime.',
      timestamp: DateTime.now().subtract(const Duration(hours: 23)),
      isRead: true,
    ),
  ];

  // Add a new message
  void addMessage(Message message) {
    _messages.add(message);
  }

  // Get messages between two users
  List<Message> getMessagesBetween(String user1Id, String user2Id) {
    return _messages
        .where(
          (message) =>
              (message.senderId == user1Id && message.receiverId == user2Id) ||
              (message.senderId == user2Id && message.receiverId == user1Id),
        )
        .toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
  }

  // Get conversations for a user
  List<Map<String, dynamic>> getConversations(String userId) {
    final Map<String, Map<String, dynamic>> conversations = {};

    for (var message in _messages) {
      final otherUserId = message.senderId == userId
          ? message.receiverId
          : message.senderId;
      final otherUserName = message.senderId == userId
          ? message.receiverId
          : message.senderName;

      if (!conversations.containsKey(otherUserId)) {
        conversations[otherUserId] = {
          'userId': otherUserId,
          'userName': otherUserName,
          'lastMessage': message.text,
          'timestamp': message.timestamp,
          'unreadCount': 0,
        };
      }

      // Update last message if newer
      if (message.timestamp.compareTo(
            conversations[otherUserId]!['timestamp'],
          ) >
          0) {
        conversations[otherUserId]!['lastMessage'] = message.text;
        conversations[otherUserId]!['timestamp'] = message.timestamp;
      }

      // Count unread messages
      if (!message.isRead && message.receiverId == userId) {
        conversations[otherUserId]!['unreadCount'] =
            (conversations[otherUserId]!['unreadCount'] as int) + 1;
      }
    }

    return conversations.values.toList()
      ..sort((a, b) => b['timestamp'].compareTo(a['timestamp']));
  }

  // Mark messages as read
  void markMessagesAsRead(String userId, String otherUserId) {
    for (var i = 0; i < _messages.length; i++) {
      if (_messages[i].senderId == otherUserId &&
          _messages[i].receiverId == userId &&
          !_messages[i].isRead) {
        _messages[i] = Message(
          id: _messages[i].id,
          senderId: _messages[i].senderId,
          senderName: _messages[i].senderName,
          receiverId: _messages[i].receiverId,
          text: _messages[i].text,
          timestamp: _messages[i].timestamp,
          isRead: true,
        );
      }
    }
  }

  // Get unread message count for a user
  int getUnreadMessageCount(String userId) {
    return _messages
        .where((message) => message.receiverId == userId && !message.isRead)
        .length;
  }
}

// ==============================================
// FILE VIEWER WIDGETS (FROM ORIGINAL CODE)
// ==============================================

class PDFViewerScreen extends StatefulWidget {
  final File pdfFile;
  final String fileName;

  const PDFViewerScreen({
    super.key,
    required this.pdfFile,
    required this.fileName,
  });

  @override
  State<PDFViewerScreen> createState() => _PDFViewerScreenState();
}

class _PDFViewerScreenState extends State<PDFViewerScreen> {
  late PdfControllerPinch pdfController;
  bool _isLoading = true;
  int _totalPages = 0;
  int _currentPage = 1;

  @override
  void initState() {
    super.initState();
    pdfController = PdfControllerPinch(
      document: PdfDocument.openFile(widget.pdfFile.path),
    );
    _loadPdfInfo();
  }

  Future<void> _loadPdfInfo() async {
    try {
      final document = await PdfDocument.openFile(widget.pdfFile.path);
      setState(() {
        _totalPages = document.pagesCount;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    pdfController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Downloading ${widget.fileName}...'),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Page navigation
                Container(
                  padding: const EdgeInsets.all(8),
                  color: Colors.grey[100],
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.chevron_left),
                        onPressed: _currentPage > 1
                            ? () {
                                pdfController.previousPage(
                                  curve: Curves.easeIn,
                                  duration: const Duration(milliseconds: 300),
                                );
                              }
                            : null,
                      ),
                      Text(
                        'Page $_currentPage of $_totalPages',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      IconButton(
                        icon: const Icon(Icons.chevron_right),
                        onPressed: _currentPage < _totalPages
                            ? () {
                                pdfController.nextPage(
                                  curve: Curves.easeIn,
                                  duration: const Duration(milliseconds: 300),
                                );
                              }
                            : null,
                      ),
                    ],
                  ),
                ),
                // PDF Viewer
                Expanded(
                  child: PdfViewPinch(
                    controller: pdfController,
                    onDocumentLoaded: (document) {
                      setState(() {
                        _totalPages = document.pagesCount;
                      });
                    },
                    onPageChanged: (page) {
                      setState(() {
                        _currentPage = page;
                      });
                    },
                    builders: PdfViewPinchBuilders<DefaultBuilderOptions>(
                      options: const DefaultBuilderOptions(),
                      documentLoaderBuilder: (_) =>
                          const Center(child: CircularProgressIndicator()),
                      pageLoaderBuilder: (_) =>
                          const Center(child: CircularProgressIndicator()),
                      errorBuilder: (_, error) =>
                          Center(child: Text(error.toString())),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class ImageViewerScreen extends StatelessWidget {
  final File imageFile;
  final String fileName;

  const ImageViewerScreen({
    super.key,
    required this.imageFile,
    required this.fileName,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Downloading $fileName...'),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
          ),
        ],
      ),
      body: PhotoView(
        imageProvider: FileImage(imageFile),
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        minScale: PhotoViewComputedScale.contained,
        maxScale: PhotoViewComputedScale.covered * 2,
        initialScale: PhotoViewComputedScale.contained,
        heroAttributes: PhotoViewHeroAttributes(tag: fileName),
        loadingBuilder: (context, event) => Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              value: event == null
                  ? 0
                  : event.cumulativeBytesLoaded / event.expectedTotalBytes!,
            ),
          ),
        ),
      ),
    );
  }
}

// ==============================================
// UPDATED STORAGE MANAGER FOR FILES (FROM ORIGINAL)
// ==============================================

class FileStorageManager {
  static final FileStorageManager _instance = FileStorageManager._internal();

  factory FileStorageManager() {
    return _instance;
  }

  FileStorageManager._internal();

  // Store files with their paper IDs
  final Map<String, File> _fileStorage = {};
  final Map<String, String> _filePaths = {};
  final Map<String, String> _fileTypes =
      {}; // Store file type (PDF, IMAGE, etc.)

  // Store file
  void storeFile(String paperId, File file, String fileType) {
    _fileStorage[paperId] = file;
    _filePaths[paperId] = file.path;
    _fileTypes[paperId] = fileType;
  }

  // Get file
  File? getFile(String paperId) {
    return _fileStorage[paperId];
  }

  // Get file path
  String? getFilePath(String paperId) {
    return _filePaths[paperId];
  }

  // Get file type
  String? getFileType(String paperId) {
    return _fileTypes[paperId];
  }

  // Check if file is image
  bool isImageFile(String paperId) {
    final fileType = _fileTypes[paperId] ?? '';
    final path = _filePaths[paperId] ?? '';
    return fileType.toLowerCase().contains('image') ||
        path.toLowerCase().endsWith('.jpg') ||
        path.toLowerCase().endsWith('.jpeg') ||
        path.toLowerCase().endsWith('.png') ||
        path.toLowerCase().endsWith('.gif') ||
        path.toLowerCase().endsWith('.bmp') ||
        path.toLowerCase().endsWith('.webp');
  }

  // Check if file is PDF
  bool isPdfFile(String paperId) {
    final fileType = _fileTypes[paperId] ?? '';
    final path = _filePaths[paperId] ?? '';
    return fileType.toLowerCase().contains('pdf') ||
        path.toLowerCase().endsWith('.pdf');
  }

  // Check if file is document
  bool isDocumentFile(String paperId) {
    final fileType = _fileTypes[paperId] ?? '';
    final path = _filePaths[paperId] ?? '';
    return fileType.toLowerCase().contains('doc') ||
        path.toLowerCase().endsWith('.doc') ||
        path.toLowerCase().endsWith('.docx') ||
        path.toLowerCase().endsWith('.txt');
  }

  // Remove file
  void removeFile(String paperId) {
    _fileStorage.remove(paperId);
    _filePaths.remove(paperId);
    _fileTypes.remove(paperId);
  }

  // Check if file exists
  bool hasFile(String paperId) {
    return _fileStorage.containsKey(paperId);
  }
}

// ==============================================
// GLOBAL DATA MANAGEMENT (FROM ORIGINAL)
// ==============================================

class PaperDataManager {
  static final PaperDataManager _instance = PaperDataManager._internal();

  factory PaperDataManager() {
    return _instance;
  }

  PaperDataManager._internal();

  // File storage manager
  final FileStorageManager fileStorage = FileStorageManager();

  // Message manager
  final MessageManager messageManager = MessageManager();

  // SHARED PAPERS LIST - Both Admin and Student can access
  List<Map<String, dynamic>> allPapers = [
    {
      'id': '1',
      'title': 'Introduction to Machine Learning',
      'studentId': 'STU2024001',
      'studentName': 'John Doe',
      'subject': 'Computer Science',
      'date': '2024-01-15',
      'fileSize': '12MB',
      'status': 'pending',
      'fileType': 'PDF',
      'fileExtension': '.pdf',
      'abstract':
          'This paper explores the fundamentals of machine learning algorithms.',
      'uploadedBy': 'student',
      'isPublic': false,
      'hasFile': true,
    },
    {
      'id': '2',
      'title': 'Quantum Physics Research',
      'studentId': 'STU2024002',
      'studentName': 'Jane Smith',
      'subject': 'Physics',
      'date': '2024-01-10',
      'fileSize': '8MB',
      'status': 'approved',
      'fileType': 'PDF',
      'fileExtension': '.pdf',
      'abstract': 'Research on quantum mechanics principles.',
      'grade': 'A',
      'feedback': 'Excellent research work',
      'uploadedBy': 'student',
      'isPublic': true,
      'hasFile': true,
    },
    {
      'id': '3',
      'title': 'Advanced Mathematics Paper',
      'studentId': 'ADMIN',
      'studentName': 'Admin Fahdil',
      'subject': 'Mathematics',
      'date': '2024-01-20',
      'fileSize': '5MB',
      'status': 'approved',
      'fileType': 'PDF',
      'fileExtension': '.pdf',
      'abstract': 'Admin uploaded mathematics paper for students.',
      'grade': 'A',
      'feedback': 'Uploaded by admin',
      'uploadedBy': 'admin',
      'isPublic': true,
      'hasFile': true,
    },
    {
      'id': '4',
      'title': 'Chemistry Research Paper',
      'studentId': 'STU2024003',
      'studentName': 'Robert Johnson',
      'subject': 'Chemistry',
      'date': '2024-01-18',
      'fileSize': '3MB',
      'status': 'approved',
      'fileType': 'IMAGE',
      'fileExtension': '.jpg',
      'abstract': 'Research on chemical reactions.',
      'grade': 'B+',
      'feedback': 'Good work, needs more references',
      'uploadedBy': 'student',
      'isPublic': true,
      'hasFile': true,
    },
  ];

  // NOTIFICATIONS FOR ADMIN
  List<Map<String, dynamic>> adminNotifications = [
    {
      'id': '1',
      'title': 'New Paper Submission',
      'message': 'John Doe submitted "Introduction to Machine Learning"',
      'time': '2 hours ago',
      'read': false,
    },
  ];

  // Add new paper
  void addPaper(Map<String, dynamic> paper, {File? file, String? fileType}) {
    allPapers.add(paper);
    if (file != null && fileType != null) {
      fileStorage.storeFile(paper['id'], file, fileType);
    }
  }

  // Update paper status
  void updatePaperStatus(
    String paperId,
    String status, {
    String? grade,
    String? feedback,
  }) {
    final index = allPapers.indexWhere((paper) => paper['id'] == paperId);
    if (index != -1) {
      allPapers[index]['status'] = status;
      if (grade != null) {
        allPapers[index]['grade'] = grade;
      }
      if (feedback != null) {
        allPapers[index]['feedback'] = feedback;
      }
      if (status == 'approved') {
        allPapers[index]['isPublic'] = true;
      }
    }
  }

  // Add notification for admin
  void addNotification(String title, String message) {
    adminNotifications.insert(0, {
      'id': 'NT${DateTime.now().millisecondsSinceEpoch}',
      'title': title,
      'message': message,
      'time': 'Just now',
      'read': false,
    });
  }

  // Get pending papers
  List<Map<String, dynamic>> getPendingPapers() {
    return allPapers.where((paper) => paper['status'] == 'pending').toList();
  }

  // Get approved papers (public)
  List<Map<String, dynamic>> getApprovedPapers() {
    return allPapers.where((paper) => paper['status'] == 'approved').toList();
  }

  // Get all public papers
  List<Map<String, dynamic>> getPublicPapers() {
    return allPapers.where((paper) => paper['isPublic'] == true).toList();
  }

  // Remove paper completely
  void removePaper(String paperId) {
    allPapers.removeWhere((paper) => paper['id'] == paperId);
    fileStorage.removeFile(paperId);
  }

  // Get file for paper
  File? getPaperFile(String paperId) {
    return fileStorage.getFile(paperId);
  }

  // Get file type for paper
  String? getPaperFileType(String paperId) {
    return fileStorage.getFileType(paperId);
  }

  // Check if paper has file
  bool paperHasFile(String paperId) {
    return fileStorage.hasFile(paperId);
  }

  // Check if file is image
  bool isPaperFileImage(String paperId) {
    return fileStorage.isImageFile(paperId);
  }

  // Check if file is PDF
  bool isPaperFilePdf(String paperId) {
    return fileStorage.isPdfFile(paperId);
  }

  // Check if file is document
  bool isPaperFileDocument(String paperId) {
    return fileStorage.isDocumentFile(paperId);
  }
}

// ==============================================
// ADMIN HOME PAGE (FROM ORIGINAL)
// ==============================================

class AdminHomePage extends StatefulWidget {
  const AdminHomePage({super.key});

  @override
  State<AdminHomePage> createState() => _AdminHomePageState();
}

class _AdminHomePageState extends State<AdminHomePage> {
  final PaperDataManager _dataManager = PaperDataManager();
  final MessageManager _messageManager = MessageManager();

  // UPDATED: FILE PICKER STATE FOR ADMIN (SUPPORTS PDF & IMAGES)
  File? _selectedAdminFile;
  String? _selectedFileType;
  String? _selectedFileExtension;
  final ImagePicker _picker = ImagePicker();

  // UPDATED: FUNCTION TO PICK FILE FOR ADMIN (SUPPORTS PDF & IMAGES)
  Future<void> _pickAdminFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png'],
    );

    if (result != null && result.files.single.path != null) {
      setState(() {
        _selectedAdminFile = File(result.files.single.path!);
        _selectedFileExtension = result.files.single.extension;
        _selectedFileType = _getFileTypeFromExtension(_selectedFileExtension);
      });
    }
  }

  // FUNCTION TO PICK IMAGE (CAMERA/GALLERY)
  Future<void> _pickAdminImage(ImageSource source) async {
    final XFile? file = await _picker.pickImage(
      source: source,
      imageQuality: 85,
    );

    if (file != null) {
      setState(() {
        _selectedAdminFile = File(file.path);
        _selectedFileExtension = 'jpg';
        _selectedFileType = 'IMAGE';
      });
    }
  }

  String _getFileTypeFromExtension(String? extension) {
    if (extension == null) return 'FILE';
    switch (extension.toLowerCase()) {
      case 'pdf':
        return 'PDF';
      case 'jpg':
      case 'jpeg':
      case 'png':
        return 'IMAGE';
      default:
        return 'FILE';
    }
  }

  IconData _getFileIcon(String? fileType) {
    switch (fileType?.toLowerCase()) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'image':
        return Icons.image;
      default:
        return Icons.insert_drive_file;
    }
  }

  Color _getFileColor(String? fileType) {
    switch (fileType?.toLowerCase()) {
      case 'pdf':
        return Colors.red;
      case 'image':
        return Colors.green;
      default:
        return Colors.grey;
    }
  }

  // OPEN FILE VIEWER
  void _openFileViewer(BuildContext context, String paperId) {
    final file = _dataManager.getPaperFile(paperId);
    final fileName = _dataManager.allPapers.firstWhere(
      (paper) => paper['id'] == paperId,
    )['title'];

    if (file == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('File not found'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    if (_dataManager.isPaperFilePdf(paperId)) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) =>
              PDFViewerScreen(pdfFile: file, fileName: fileName),
        ),
      );
    } else if (_dataManager.isPaperFileImage(paperId)) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) =>
              ImageViewerScreen(imageFile: file, fileName: fileName),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('File type not supported for preview'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _acceptPaper(String paperId, String grade, String feedback) {
    setState(() {
      _dataManager.updatePaperStatus(
        paperId,
        'approved',
        grade: grade,
        feedback: feedback,
      );
    });
  }

  void _rejectPaper(String paperId, String reason) {
    setState(() {
      final index = _dataManager.allPapers.indexWhere(
        (paper) => paper['id'] == paperId,
      );
      if (index != -1) {
        _dataManager.allPapers[index]['status'] = 'rejected';
        _dataManager.allPapers[index]['rejectionReason'] = reason;
        _dataManager.allPapers[index]['reviewedDate'] = DateTime.now()
            .toString()
            .split(' ')[0];
      }
    });
  }

  // REMOVE PAPER COMPLETELY (EVEN IF APPROVED)
  void _removePaper(String paperId) {
    setState(() {
      _dataManager.removePaper(paperId);
    });
  }

  void _uploadPaperAsAdmin(Map<String, dynamic> paperData) {
    setState(() {
      final newPaper = {
        ...paperData,
        'id': 'ADM${DateTime.now().millisecondsSinceEpoch}',
        'uploadedBy': 'Admin Fahdil',
        'uploadDate': DateTime.now().toString().split(' ')[0],
        'status': 'approved',
        'isPublic': true,
        'grade': 'A',
        'feedback': 'Uploaded by admin',
        'hasFile': _selectedAdminFile != null,
        'fileType': _selectedFileType ?? 'FILE',
        'fileExtension': _selectedFileExtension != null
            ? '.$_selectedFileExtension'
            : '.file',
      };

      _dataManager.addPaper(
        newPaper,
        file: _selectedAdminFile,
        fileType: _selectedFileType,
      );
      _dataManager.addNotification(
        'Admin Upload',
        'Admin uploaded "${paperData['title']}"',
      );
    });

    // Reset file selection
    setState(() {
      _selectedAdminFile = null;
      _selectedFileType = null;
      _selectedFileExtension = null;
    });
  }

  // MARK NOTIFICATION AS READ
  void _markNotificationAsRead(String notificationId) {
    setState(() {
      final index = _dataManager.adminNotifications.indexWhere(
        (notification) => notification['id'] == notificationId,
      );
      if (index != -1) {
        _dataManager.adminNotifications[index]['read'] = true;
      }
    });
  }

  // GET UNREAD NOTIFICATIONS COUNT
  int getUnreadNotificationsCount() {
    return _dataManager.adminNotifications
        .where((n) => n['read'] == false)
        .length;
  }

  // GET UNREAD MESSAGES COUNT
  int getUnreadMessagesCount() {
    return _messageManager.getUnreadMessageCount('ADMIN');
  }

  @override
  Widget build(BuildContext context) {
    final pendingPapers = _dataManager.getPendingPapers();
    final approvedPapers = _dataManager.getApprovedPapers();
    final unreadNotificationsCount = getUnreadNotificationsCount();
    final unreadMessagesCount = getUnreadMessagesCount();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Management'),
        actions: [
          // MESSAGES ICON WITH BADGE
          Stack(
            children: [
              IconButton(
                icon: const Icon(Icons.chat),
                onPressed: () => _showAdminMessages(context),
                tooltip: 'Messages',
              ),
              if (unreadMessagesCount > 0)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                      color: Colors.blue,
                      shape: BoxShape.circle,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 16,
                      minHeight: 16,
                    ),
                    child: Text(
                      unreadMessagesCount.toString(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
          // NOTIFICATION BELL WITH BADGE
          Stack(
            children: [
              IconButton(
                icon: const Icon(Icons.notifications),
                onPressed: () => _showNotifications(context),
                tooltip: 'Notifications',
              ),
              if (unreadNotificationsCount > 0)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 16,
                      minHeight: 16,
                    ),
                    child: Text(
                      unreadNotificationsCount.toString(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.upload),
            onPressed: () => _showAdminUploadDialog(context),
            tooltip: 'Upload Paper',
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (context) => const WelcomePage()),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.admin_panel_settings,
                size: 150,
                color: Colors.blue,
              ),
              const SizedBox(height: 20),
              const Text(
                'Welcome Fahdil',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              const Text(
                'Paper review & communication management',
                style: TextStyle(
                  fontSize: 17,
                  color: Color.fromARGB(255, 15, 10, 145),
                ),
              ),
              const SizedBox(height: 30),
              Wrap(
                spacing: 0,
                runSpacing: 0,
                alignment: WrapAlignment.center,
                children: [
                  _buildAdminFeatureCard(
                    icon: Icons.pending_actions,
                    title: 'Pending Papers',
                    color: Colors.orange,
                    count: pendingPapers.length,
                    onTap: () {
                      _showPendingPapersScreen(context);
                    },
                  ),
                  _buildAdminFeatureCard(
                    icon: Icons.approval,
                    title: 'Approved Papers',
                    color: Colors.green,
                    count: approvedPapers.length,
                    onTap: () {
                      _showApprovedPapersScreen(context);
                    },
                  ),
                  _buildAdminFeatureCard(
                    icon: Icons.chat,
                    title: 'Messages',
                    color: Colors.blue,
                    count: unreadMessagesCount,
                    onTap: () {
                      _showAdminMessages(context);
                    },
                  ),
                  _buildAdminFeatureCard(
                    icon: Icons.notifications,
                    title: 'Notifications',
                    color: Colors.red,
                    count: unreadNotificationsCount,
                    onTap: () {
                      _showNotifications(context);
                    },
                  ),
                  _buildAdminFeatureCard(
                    icon: Icons.upload_file,
                    title: 'Upload Paper',
                    color: Colors.purple,
                    onTap: () {
                      _showAdminUploadDialog(context);
                    },
                  ),
                  _buildAdminFeatureCard(
                    icon: Icons.analytics,
                    title: 'Analytics',
                    color: Colors.teal,
                    onTap: () {
                      _showAnalyticsScreen(context);
                    },
                  ),
                  _buildAdminFeatureCard(
                    icon: Icons.delete,
                    title: 'Manage Files',
                    color: Colors.red,
                    onTap: () {
                      _showFileManagementScreen(context);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAdminFeatureCard({
    required IconData icon,
    required String title,
    required Color color,
    int? count,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 150,
        height: 150,
        margin: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.3)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 5,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Stack(
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 50, color: color),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (count != null && count > 0)
              Positioned(
                top: 10,
                right: 10,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    count.toString(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ADMIN MESSAGES SCREEN
  void _showAdminMessages(BuildContext context) {
    final conversations = _messageManager.getConversations('ADMIN');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(20),
          height: MediaQuery.of(context).size.height * 0.9,
          child: Column(
            children: [
              const Text(
                'Messages',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              const Text(
                'Communicate with students',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: conversations.isEmpty
                    ? const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.chat, size: 60, color: Colors.grey),
                            SizedBox(height: 10),
                            Text(
                              'No messages yet',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        itemCount: conversations.length,
                        itemBuilder: (context, index) {
                          final conversation = conversations[index];
                          return _buildConversationItem(conversation, context);
                        },
                      ),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                },
                child: const Text('Close'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildConversationItem(
    Map<String, dynamic> conversation,
    BuildContext context,
  ) {
    final unreadCount = conversation['unreadCount'] as int;
    final timestamp = conversation['timestamp'] as DateTime;
    final timeAgo = _getTimeAgo(timestamp);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: const CircleAvatar(
          backgroundColor: Colors.blue,
          child: Icon(Icons.person, color: Colors.white),
        ),
        title: Text(
          conversation['userName'],
          style: TextStyle(
            fontWeight: unreadCount > 0 ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              conversation['lastMessage'],
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: unreadCount > 0
                    ? FontWeight.w500
                    : FontWeight.normal,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              timeAgo,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        trailing: unreadCount > 0
            ? Container(
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(
                  color: Colors.blue,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  unreadCount.toString(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              )
            : null,
        onTap: () {
          _openChatWithStudent(context, conversation['userId']);
        },
      ),
    );
  }

  void _openChatWithStudent(BuildContext context, String studentId) {
    final student = _dataManager.allPapers.firstWhere(
      (paper) => paper['studentId'] == studentId,
      orElse: () => {
        'studentId': studentId,
        'studentName': 'Student $studentId',
      },
    );

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          otherUserId: studentId,
          otherUserName: student['studentName'] ?? 'Student',
          currentUserId: 'ADMIN',
          currentUserName: 'Admin Fahdil',
          messageManager: _messageManager,
        ),
      ),
    );
  }

  String _getTimeAgo(DateTime timestamp) {
    final now = DateTime.now();
    final difference = now.difference(timestamp);

    if (difference.inSeconds < 60) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}d ago';
    } else {
      return '${timestamp.day}/${timestamp.month}/${timestamp.year}';
    }
  }

  void _showPendingPapersScreen(BuildContext context) {
    final pendingPapers = _dataManager.getPendingPapers();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return Container(
              padding: const EdgeInsets.all(20),
              height: MediaQuery.of(context).size.height * 0.9,
              child: Column(
                children: [
                  const Text(
                    'Pending Papers for Approval',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: pendingPapers.isEmpty
                        ? const Center(
                            child: Text(
                              'No pending papers',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.grey,
                              ),
                            ),
                          )
                        : ListView.builder(
                            itemCount: pendingPapers.length,
                            itemBuilder: (context, index) {
                              final paper = pendingPapers[index];
                              return _buildPendingPaperItem(paper, context);
                            },
                          ),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      Navigator.pop(context);
                    },
                    child: const Text('Close'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPendingPaperItem(
    Map<String, dynamic> paper,
    BuildContext context,
  ) {
    final fileType = _dataManager.getPaperFileType(paper['id']);
    final icon = _getFileIcon(fileType);
    final color = _getFileColor(fileType);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: GestureDetector(
          onTap: () {
            _openFileViewer(context, paper['id']);
          },
          child: Icon(icon, color: color, size: 40),
        ),
        title: Text(
          paper['title'],
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Student: ${paper['studentName']} (${paper['studentId']})'),
            Text('Subject: ${paper['subject']}'),
            Text('Date: ${paper['date']} • Size: ${paper['fileSize']}'),
            Wrap(
              spacing: 4,
              children: [
                Chip(
                  label: Text(paper['fileType']),
                  backgroundColor: Colors.grey[200],
                  labelStyle: const TextStyle(fontSize: 10),
                ),
                if (fileType != null)
                  Chip(
                    label: Text(fileType),
                    backgroundColor: color.withOpacity(0.2),
                    labelStyle: TextStyle(fontSize: 10, color: color),
                  ),
              ],
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.visibility, color: Colors.blue),
              onPressed: () {
                _viewPaperDetails(context, paper);
              },
              tooltip: 'View Details',
            ),
            IconButton(
              icon: const Icon(Icons.check_circle, color: Colors.green),
              onPressed: () {
                _showAcceptPaperDialog(context, paper);
              },
              tooltip: 'Accept Paper',
            ),
            IconButton(
              icon: const Icon(Icons.cancel, color: Colors.red),
              onPressed: () {
                _showRejectPaperDialog(context, paper);
              },
              tooltip: 'Reject Paper',
            ),
          ],
        ),
      ),
    );
  }

  void _showAcceptPaperDialog(
    BuildContext context,
    Map<String, dynamic> paper,
  ) {
    final gradeController = TextEditingController();
    final feedbackController = TextEditingController();
    String selectedGrade = 'A';

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Accept Paper'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Accepting: ${paper['title']}'),
                    Text('Student ID: ${paper['studentId']}'),
                    const SizedBox(height: 20),
                    const Text('Assign Grade:'),
                    DropdownButtonFormField<String>(
                      initialValue: selectedGrade,
                      items: const [
                        DropdownMenuItem(value: 'A', child: Text('A')),
                        DropdownMenuItem(value: 'B+', child: Text('B+')),
                        DropdownMenuItem(value: 'B', child: Text('B')),
                        DropdownMenuItem(value: 'C+', child: Text('C+')),
                        DropdownMenuItem(value: 'C', child: Text('C')),
                        DropdownMenuItem(value: 'D', child: Text('D')),
                        DropdownMenuItem(value: 'F', child: Text('F')),
                      ],
                      onChanged: (value) {
                        setState(() {
                          selectedGrade = value!;
                        });
                      },
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: feedbackController,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Feedback (Optional)',
                        border: OutlineInputBorder(),
                        hintText: 'Enter your feedback here...',
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (selectedGrade.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Please select a grade'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                      return;
                    }

                    _acceptPaper(
                      paper['id'],
                      selectedGrade,
                      feedbackController.text,
                    );
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Paper "${paper['title']}" approved with grade $selectedGrade',
                        ),
                        duration: const Duration(seconds: 3),
                        backgroundColor: Colors.green,
                      ),
                    );

                    // ADD NOTIFICATION
                    _dataManager.addNotification(
                      'Paper Approved',
                      'You approved "${paper['title']}" with grade $selectedGrade',
                    );

                    // SEND MESSAGE TO STUDENT
                    _messageManager.addMessage(
                      Message(
                        id: 'MSG${DateTime.now().millisecondsSinceEpoch}',
                        senderId: 'ADMIN',
                        senderName: 'Admin Fahdil',
                        receiverId: paper['studentId'],
                        text:
                            'Your paper "${paper['title']}" has been approved with grade $selectedGrade. Feedback: ${feedbackController.text.isNotEmpty ? feedbackController.text : "Good work!"}',
                        timestamp: DateTime.now(),
                      ),
                    );

                    setState(() {});
                  },
                  child: const Text('Approve Paper'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showRejectPaperDialog(
    BuildContext context,
    Map<String, dynamic> paper,
  ) {
    final reasonController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Reject Paper'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Rejecting: ${paper['title']}'),
              Text('Student ID: ${paper['studentId']}'),
              const SizedBox(height: 20),
              TextField(
                controller: reasonController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Reason for rejection',
                  border: OutlineInputBorder(),
                  hintText: 'Enter the reason for rejection...',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                if (reasonController.text.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Please provide a reason for rejection'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                  return;
                }
                _rejectPaper(paper['id'], reasonController.text);
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Paper "${paper['title']}" rejected'),
                    duration: const Duration(seconds: 3),
                    backgroundColor: Colors.red,
                  ),
                );

                // ADD NOTIFICATION
                _dataManager.addNotification(
                  'Paper Rejected',
                  'You rejected "${paper['title']}"',
                );

                // SEND MESSAGE TO STUDENT
                _messageManager.addMessage(
                  Message(
                    id: 'MSG${DateTime.now().millisecondsSinceEpoch}',
                    senderId: 'ADMIN',
                    senderName: 'Admin Fahdil',
                    receiverId: paper['studentId'],
                    text:
                        'Your paper "${paper['title']}" has been rejected. Reason: ${reasonController.text}',
                    timestamp: DateTime.now(),
                  ),
                );

                setState(() {});
              },
              child: const Text('Reject Paper'),
            ),
          ],
        );
      },
    );
  }

  void _viewPaperDetails(BuildContext context, Map<String, dynamic> paper) {
    final hasFile = _dataManager.paperHasFile(paper['id']);
    final file = _dataManager.getPaperFile(paper['id']);
    final isImage = _dataManager.isPaperFileImage(paper['id']);
    final isPdf = _dataManager.isPaperFilePdf(paper['id']);
    final fileType = _dataManager.getPaperFileType(paper['id']);

    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          insetPadding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          paper['title'],
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),

                  // FILE PREVIEW SECTION
                  if (hasFile && file != null)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Uploaded File:',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 10),

                        // Show image preview
                        if (isImage)
                          GestureDetector(
                            onTap: () {
                              Navigator.pop(context);
                              _openFileViewer(context, paper['id']);
                            },
                            child: Container(
                              width: double.infinity,
                              height: 300,
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Stack(
                                children: [
                                  Image.file(
                                    file,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) {
                                      return const Center(
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Icon(
                                              Icons.broken_image,
                                              size: 60,
                                              color: Colors.grey,
                                            ),
                                            SizedBox(height: 10),
                                            Text('Unable to load image'),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                  Positioned(
                                    bottom: 10,
                                    right: 10,
                                    child: Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withOpacity(0.7),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: const Row(
                                        children: [
                                          Icon(
                                            Icons.fullscreen,
                                            size: 16,
                                            color: Colors.white,
                                          ),
                                          SizedBox(width: 4),
                                          Text(
                                            'Tap to view fullscreen',
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        // Show PDF/document preview
                        else
                          GestureDetector(
                            onTap: () {
                              Navigator.pop(context);
                              _openFileViewer(context, paper['id']);
                            },
                            child: Container(
                              width: double.infinity,
                              height: 200,
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey),
                                borderRadius: BorderRadius.circular(8),
                                color: Colors.grey[100],
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    _getFileIcon(fileType),
                                    size: 80,
                                    color: _getFileColor(fileType),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    '${paper['fileType']} Document',
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    'File: ${file.path.split('/').last}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 10),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: _getFileColor(
                                        fileType,
                                      ).withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color: _getFileColor(fileType),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.visibility,
                                          size: 14,
                                          color: _getFileColor(fileType),
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          'Tap to view full document',
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: _getFileColor(fileType),
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        const SizedBox(height: 20),
                      ],
                    ),

                  // Paper Details
                  const Text(
                    'Paper Details:',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),

                  _buildDetailRow('Student:', paper['studentName']),
                  _buildDetailRow('Student ID:', paper['studentId']),
                  _buildDetailRow('Subject:', paper['subject']),
                  _buildDetailRow('Submitted:', paper['date']),
                  _buildDetailRow('File Size:', paper['fileSize']),
                  _buildDetailRow('Format:', paper['fileType']),
                  _buildDetailRow('Status:', paper['status']),

                  if (paper['grade'] != null)
                    _buildDetailRow('Grade:', paper['grade']),

                  const SizedBox(height: 20),

                  const Text(
                    'Abstract:',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  Text(paper['abstract'] ?? 'No abstract available'),

                  if (paper['feedback'] != null &&
                      paper['feedback'].isNotEmpty) ...[
                    const SizedBox(height: 20),
                    const Text(
                      'Feedback:',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(paper['feedback']),
                  ],

                  const SizedBox(height: 30),

                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Close'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      if (hasFile)
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () {
                              _openFileViewer(context, paper['id']);
                            },
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.visibility, size: 16),
                                SizedBox(width: 5),
                                Text('View File'),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w500,
                color: Colors.grey,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  void _showApprovedPapersScreen(BuildContext context) {
    final approvedPapers = _dataManager.getApprovedPapers();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(20),
          height: MediaQuery.of(context).size.height * 0.9,
          child: Column(
            children: [
              const Text(
                'Approved Papers (Public)',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: approvedPapers.isEmpty
                    ? const Center(
                        child: Text(
                          'No approved papers yet',
                          style: TextStyle(fontSize: 16, color: Colors.grey),
                        ),
                      )
                    : ListView.builder(
                        itemCount: approvedPapers.length,
                        itemBuilder: (context, index) {
                          final paper = approvedPapers[index];
                          return _buildApprovedPaperItem(paper, context);
                        },
                      ),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                },
                child: const Text('Close'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildApprovedPaperItem(
    Map<String, dynamic> paper,
    BuildContext context,
  ) {
    final hasFile = _dataManager.paperHasFile(paper['id']);
    final fileType = _dataManager.getPaperFileType(paper['id']);
    final icon = _getFileIcon(fileType);
    final color = _getFileColor(fileType);
    final isImage = _dataManager.isPaperFileImage(paper['id']);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: GestureDetector(
          onTap: () {
            _openFileViewer(context, paper['id']);
          },
          child: Stack(
            children: [
              Icon(icon, color: color, size: 40),
              if (isImage)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: Colors.green,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.image,
                      size: 12,
                      color: Colors.white,
                    ),
                  ),
                ),
            ],
          ),
        ),
        title: Text(
          paper['title'],
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Student: ${paper['studentName']} (${paper['studentId']})'),
            Text('Subject: ${paper['subject']}'),
            Text('Date: ${paper['date']} • Grade: ${paper['grade'] ?? 'N/A'}'),
            if (paper['feedback'] != null && paper['feedback'].isNotEmpty)
              Text('Feedback: ${paper['feedback']}'),
            Wrap(
              spacing: 4,
              children: [
                Chip(
                  label: const Text('Public'),
                  backgroundColor: Colors.green[100],
                  labelStyle: const TextStyle(fontSize: 10),
                ),
                if (hasFile)
                  Chip(
                    label: Text(fileType ?? 'File'),
                    backgroundColor: color.withOpacity(0.2),
                    labelStyle: TextStyle(fontSize: 10, color: color),
                  ),
              ],
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.visibility, color: Colors.blue),
              onPressed: () {
                _viewApprovedPaperDetails(context, paper);
              },
              tooltip: 'View Details',
            ),
            IconButton(
              icon: const Icon(Icons.download, color: Colors.green),
              onPressed: () {
                _downloadPaper(paper);
              },
              tooltip: 'Download',
            ),
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.red),
              onPressed: () {
                _showDeleteApprovedPaperDialog(context, paper);
              },
              tooltip: 'Delete',
            ),
          ],
        ),
      ),
    );
  }

  void _showDeleteApprovedPaperDialog(
    BuildContext context,
    Map<String, dynamic> paper,
  ) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete Approved Paper'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Are you sure you want to delete "${paper['title']}"?'),
              const SizedBox(height: 10),
              const Text(
                '⚠️ This action cannot be undone. The paper will be permanently removed from the system.',
                style: TextStyle(color: Colors.red, fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                _removePaper(paper['id']);
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Paper "${paper['title']}" deleted permanently',
                    ),
                    duration: const Duration(seconds: 3),
                    backgroundColor: Colors.red,
                  ),
                );

                // ADD NOTIFICATION
                _dataManager.addNotification(
                  'Paper Deleted',
                  'You deleted "${paper['title']}" from the system',
                );

                setState(() {});
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Delete Permanently'),
            ),
          ],
        );
      },
    );
  }

  void _viewApprovedPaperDetails(
    BuildContext context,
    Map<String, dynamic> paper,
  ) {
    final hasFile = _dataManager.paperHasFile(paper['id']);
    final file = _dataManager.getPaperFile(paper['id']);
    final isImage = _dataManager.isPaperFileImage(paper['id']);
    final isPdf = _dataManager.isPaperFilePdf(paper['id']);
    final fileType = _dataManager.getPaperFileType(paper['id']);

    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          insetPadding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          paper['title'],
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),

                  // FILE PREVIEW SECTION
                  if (hasFile && file != null)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Uploaded File Content:',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 10),

                        if (isImage)
                          GestureDetector(
                            onTap: () {
                              Navigator.pop(context);
                              _openFileViewer(context, paper['id']);
                            },
                            child: Container(
                              width: double.infinity,
                              height: 350,
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Stack(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.file(
                                      file,
                                      fit: BoxFit.contain,
                                      errorBuilder:
                                          (context, error, stackTrace) {
                                            return const Center(
                                              child: Column(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  Icon(
                                                    Icons.broken_image,
                                                    size: 60,
                                                    color: Colors.grey,
                                                  ),
                                                  SizedBox(height: 10),
                                                  Text('Unable to load image'),
                                                ],
                                              ),
                                            );
                                          },
                                    ),
                                  ),
                                  Positioned(
                                    bottom: 10,
                                    right: 10,
                                    child: Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withOpacity(0.7),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: const Row(
                                        children: [
                                          Icon(
                                            Icons.fullscreen,
                                            size: 16,
                                            color: Colors.white,
                                          ),
                                          SizedBox(width: 4),
                                          Text(
                                            'Tap to view fullscreen',
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else
                          GestureDetector(
                            onTap: () {
                              Navigator.pop(context);
                              _openFileViewer(context, paper['id']);
                            },
                            child: Container(
                              width: double.infinity,
                              height: 250,
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey),
                                borderRadius: BorderRadius.circular(8),
                                color: Colors.grey[100],
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    _getFileIcon(fileType),
                                    size: 80,
                                    color: _getFileColor(fileType),
                                  ),
                                  const SizedBox(height: 15),
                                  Text(
                                    '${fileType ?? 'Document'} File',
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    file.path.split('/').last,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      color: Colors.grey,
                                    ),
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 20),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: _getFileColor(fileType),
                                      borderRadius: BorderRadius.circular(25),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.visibility,
                                          size: 16,
                                          color: Colors.white,
                                        ),
                                        SizedBox(width: 6),
                                        Text(
                                          'View Full Document',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        const SizedBox(height: 20),
                      ],
                    ),

                  // Paper Details
                  const Text(
                    'Paper Details:',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),

                  _buildDetailRow('Student:', paper['studentName']),
                  _buildDetailRow('Student ID:', paper['studentId']),
                  _buildDetailRow('Subject:', paper['subject']),
                  _buildDetailRow('Submitted:', paper['date']),
                  _buildDetailRow(
                    'Approved on:',
                    paper['reviewedDate'] ?? 'N/A',
                  ),
                  _buildDetailRow('Grade:', paper['grade'] ?? 'N/A'),
                  _buildDetailRow('File Size:', paper['fileSize']),
                  _buildDetailRow('File Type:', fileType ?? 'N/A'),

                  const SizedBox(height: 20),

                  if (paper['feedback'] != null &&
                      paper['feedback'].isNotEmpty) ...[
                    const Text(
                      'Feedback:',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(paper['feedback']),
                    const SizedBox(height: 20),
                  ],

                  const Text(
                    'Abstract:',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  Text(paper['abstract'] ?? 'No abstract available'),

                  const SizedBox(height: 20),

                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green[50],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.public, color: Colors.green, size: 16),
                        SizedBox(width: 8),
                        Text(
                          'This paper is publicly available to all students',
                          style: TextStyle(fontSize: 12, color: Colors.green),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 30),

                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Close'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      if (hasFile)
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () {
                              Navigator.pop(context);
                              _openFileViewer(context, paper['id']);
                            },
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.visibility, size: 16),
                                SizedBox(width: 5),
                                Text('View Full'),
                              ],
                            ),
                          ),
                        ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () {
                            Navigator.pop(context);
                            _showDeleteApprovedPaperDialog(context, paper);
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                          ),
                          child: const Text('Delete'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _downloadPaper(Map<String, dynamic> paper) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Downloading ${paper['title']}...'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showNotifications(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(20),
          height: MediaQuery.of(context).size.height * 0.9,
          child: Column(
            children: [
              const Text(
                'Admin Notifications',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _dataManager.adminNotifications.isEmpty
                    ? const Center(
                        child: Text(
                          'No notifications',
                          style: TextStyle(fontSize: 16, color: Colors.grey),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _dataManager.adminNotifications.length,
                        itemBuilder: (context, index) {
                          final notification =
                              _dataManager.adminNotifications[index];
                          return _buildNotificationItem(notification, context);
                        },
                      ),
              ),
              ElevatedButton(
                onPressed: () {
                  // Mark all as read
                  for (var notification in _dataManager.adminNotifications) {
                    notification['read'] = true;
                  }
                  setState(() {});
                  Navigator.pop(context);
                },
                child: const Text('Mark All as Read'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildNotificationItem(
    Map<String, dynamic> notification,
    BuildContext context,
  ) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: notification['read'] ? Colors.white : Colors.blue[50],
      child: ListTile(
        leading: notification['read']
            ? const Icon(Icons.notifications_none, color: Colors.grey)
            : const Icon(Icons.notifications_active, color: Colors.blue),
        title: Text(
          notification['title'],
          style: TextStyle(
            fontWeight: notification['read']
                ? FontWeight.normal
                : FontWeight.bold,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(notification['message']),
            const SizedBox(height: 4),
            Text(
              notification['time'],
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        trailing: notification['read']
            ? null
            : IconButton(
                icon: const Icon(Icons.check, size: 20),
                onPressed: () {
                  _markNotificationAsRead(notification['id']);
                },
                tooltip: 'Mark as read',
              ),
        onTap: () {
          _markNotificationAsRead(notification['id']);
        },
      ),
    );
  }

  void _showAdminUploadDialog(BuildContext context) {
    final titleController = TextEditingController();
    final subjectController = TextEditingController();
    final descriptionController = TextEditingController();
    String? selectedSubject = 'Computer Science';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return SingleChildScrollView(
              child: Container(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom,
                  left: 24,
                  right: 24,
                  top: 24,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Upload Paper as Admin',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text('Select subject:'),
                    DropdownButtonFormField<String>(
                      initialValue: selectedSubject,
                      items: const [
                        DropdownMenuItem(
                          value: 'Computer Science',
                          child: Text('Computer Science'),
                        ),
                        DropdownMenuItem(
                          value: 'Mathematics',
                          child: Text('Mathematics'),
                        ),
                        DropdownMenuItem(
                          value: 'Physics',
                          child: Text('Physics'),
                        ),
                        DropdownMenuItem(
                          value: 'Chemistry',
                          child: Text('Chemistry'),
                        ),
                        DropdownMenuItem(
                          value: 'Economics',
                          child: Text('Economics'),
                        ),
                        DropdownMenuItem(
                          value: 'General',
                          child: Text('General'),
                        ),
                      ],
                      onChanged: (value) {
                        setState(() {
                          selectedSubject = value;
                        });
                      },
                      decoration: const InputDecoration(
                        hintText: 'Choose subject',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: titleController,
                      decoration: const InputDecoration(
                        labelText: 'Paper Title',
                        border: OutlineInputBorder(),
                        hintText: 'Enter paper title',
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: descriptionController,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Description (Optional)',
                        border: OutlineInputBorder(),
                        hintText: 'Enter paper description or abstract',
                      ),
                    ),
                    const SizedBox(height: 16),

                    // UPDATED: FILE PICKER SECTION FOR PDF & IMAGES
                    Container(
                      width: double.infinity,
                      height: 200,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: _selectedAdminFile == null
                          ? const Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.cloud_upload,
                                    size: 48,
                                    color: Colors.grey,
                                  ),
                                  SizedBox(height: 8),
                                  Text('No file selected'),
                                  Text(
                                    'Select a PDF or image to upload',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey,
                                    ),
                                  ),
                                  SizedBox(height: 8),
                                  Text(
                                    'Supports: PDF, JPG, PNG',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : Column(
                              children: [
                                Expanded(
                                  child: _selectedFileType == 'IMAGE'
                                      ? Image.file(
                                          _selectedAdminFile!,
                                          fit: BoxFit.cover,
                                        )
                                      : Container(
                                          color: Colors.grey[100],
                                          child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Icon(
                                                _getFileIcon(_selectedFileType),
                                                size: 60,
                                                color: _getFileColor(
                                                  _selectedFileType,
                                                ),
                                              ),
                                              const SizedBox(height: 10),
                                              Text(
                                                '${_selectedFileType ?? 'File'} Document',
                                                style: const TextStyle(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                              const SizedBox(height: 5),
                                              Text(
                                                _selectedAdminFile!.path
                                                    .split('/')
                                                    .last,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ],
                                          ),
                                        ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.all(8.0),
                                  child: Text(
                                    _selectedAdminFile!.path.split('/').last,
                                    style: const TextStyle(fontSize: 12),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                    ),
                    const SizedBox(height: 12),

                    // UPDATED: FILE SELECTION BUTTONS
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        ElevatedButton.icon(
                          onPressed: () => _pickAdminFile(),
                          icon: const Icon(Icons.insert_drive_file),
                          label: const Text('Browse Files'),
                        ),
                        ElevatedButton.icon(
                          onPressed: () => _pickAdminImage(ImageSource.camera),
                          icon: const Icon(Icons.camera_alt),
                          label: const Text('Camera'),
                        ),
                        ElevatedButton.icon(
                          onPressed: () => _pickAdminImage(ImageSource.gallery),
                          icon: const Icon(Icons.photo),
                          label: const Text('Gallery'),
                        ),
                      ],
                    ),

                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () {
                              setState(() {
                                _selectedAdminFile = null;
                                _selectedFileType = null;
                                _selectedFileExtension = null;
                              });
                              Navigator.pop(context);
                            },
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () {
                              if (titleController.text.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Please enter a title'),
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                                return;
                              }

                              if (_selectedAdminFile == null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Please select a file'),
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                                return;
                              }

                              final paperData = {
                                'title': titleController.text,
                                'subject': selectedSubject!,
                                'fileType': _selectedFileType ?? 'FILE',
                                'description': descriptionController.text,
                                'fileSize':
                                    '${_selectedAdminFile!.lengthSync() ~/ 1024}KB',
                                'date': DateTime.now().toString().split(' ')[0],
                                'studentId': 'ADMIN',
                                'studentName': 'Admin Fahdil',
                                'abstract':
                                    descriptionController.text.isNotEmpty
                                    ? descriptionController.text
                                    : 'Paper uploaded by admin',
                              };

                              _uploadPaperAsAdmin(paperData);
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Paper uploaded and published publicly!',
                                  ),
                                  duration: const Duration(seconds: 2),
                                  backgroundColor: Colors.green,
                                ),
                              );
                            },
                            child: const Text('Upload & Publish'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showFileManagementScreen(BuildContext context) {
    final approvedPapers = _dataManager.getApprovedPapers();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(20),
          height: MediaQuery.of(context).size.height * 0.9,
          child: Column(
            children: [
              const Text(
                'File Management',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              const Text(
                'Manage and delete approved papers',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: approvedPapers.isEmpty
                    ? const Center(
                        child: Text(
                          'No approved papers to manage',
                          style: TextStyle(fontSize: 16, color: Colors.grey),
                        ),
                      )
                    : ListView.builder(
                        itemCount: approvedPapers.length,
                        itemBuilder: (context, index) {
                          final paper = approvedPapers[index];
                          return _buildFileManagementItem(paper, context);
                        },
                      ),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                },
                child: const Text('Close'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFileManagementItem(
    Map<String, dynamic> paper,
    BuildContext context,
  ) {
    final hasFile = _dataManager.paperHasFile(paper['id']);
    final fileType = _dataManager.getPaperFileType(paper['id']);
    final icon = _getFileIcon(fileType);
    final color = _getFileColor(fileType);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: GestureDetector(
          onTap: () {
            _openFileViewer(context, paper['id']);
          },
          child: Icon(icon, color: color, size: 40),
        ),
        title: Text(
          paper['title'],
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('By: ${paper['studentName']}'),
            Text('Subject: ${paper['subject']}'),
            Text('Date: ${paper['date']} • Size: ${paper['fileSize']}'),
            Wrap(
              spacing: 4,
              children: [
                Chip(
                  label: Text(paper['status']),
                  backgroundColor: Colors.green[100],
                  labelStyle: const TextStyle(fontSize: 10),
                ),
                if (hasFile)
                  Chip(
                    label: Text(fileType ?? 'File'),
                    backgroundColor: color.withOpacity(0.2),
                    labelStyle: TextStyle(fontSize: 10, color: color),
                  ),
              ],
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.visibility, color: Colors.blue),
              onPressed: () {
                _viewApprovedPaperDetails(context, paper);
              },
              tooltip: 'View',
            ),
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.red),
              onPressed: () {
                _showDeleteApprovedPaperDialog(context, paper);
              },
              tooltip: 'Delete',
            ),
          ],
        ),
      ),
    );
  }

  void _showAnalyticsScreen(BuildContext context) {
    final pendingPapers = _dataManager.getPendingPapers();
    final approvedPapers = _dataManager.getApprovedPapers();
    final publicPapers = _dataManager.getPublicPapers();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Analytics Dashboard'),
          content: SizedBox(
            height: 400,
            child: Column(
              children: [
                _buildAnalyticsItem(
                  'Total Papers',
                  '${_dataManager.allPapers.length}',
                ),
                _buildAnalyticsItem(
                  'Papers Pending Review',
                  '${pendingPapers.length}',
                ),
                _buildAnalyticsItem(
                  'Papers Approved',
                  '${approvedPapers.length}',
                ),
                _buildAnalyticsItem('Public Papers', '${publicPapers.length}'),
                _buildAnalyticsItem(
                  'Papers with Files',
                  '${_dataManager.allPapers.where((p) => p['hasFile'] == true).length}',
                ),
                _buildAnalyticsItem(
                  'PDF Files',
                  '${_dataManager.allPapers.where((p) => p['fileType'] == 'PDF').length}',
                ),
                _buildAnalyticsItem(
                  'Image Files',
                  '${_dataManager.allPapers.where((p) => p['fileType'] == 'IMAGE').length}',
                ),
                _buildAnalyticsItem(
                  'Admin Notifications',
                  '${_dataManager.adminNotifications.length}',
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'Approved papers are automatically published and available to all students',
                    style: TextStyle(fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildAnalyticsItem(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 14)),
          Text(
            value,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

// ==============================================
// CHAT SCREEN FOR MESSAGING (FROM ORIGINAL)
// ==============================================

class ChatScreen extends StatefulWidget {
  final String currentUserId;
  final String currentUserName;
  final String otherUserId;
  final String otherUserName;
  final MessageManager messageManager;

  const ChatScreen({
    super.key,
    required this.currentUserId,
    required this.currentUserName,
    required this.otherUserId,
    required this.otherUserName,
    required this.messageManager,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final List<Message> _messages = [];

  @override
  void initState() {
    super.initState();
    // Load messages
    _messages.addAll(
      widget.messageManager.getMessagesBetween(
        widget.currentUserId,
        widget.otherUserId,
      ),
    );
    // Mark messages as read
    widget.messageManager.markMessagesAsRead(
      widget.currentUserId,
      widget.otherUserId,
    );
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final newMessage = Message(
      id: 'MSG${DateTime.now().millisecondsSinceEpoch}',
      senderId: widget.currentUserId,
      senderName: widget.currentUserName,
      receiverId: widget.otherUserId,
      text: text,
      timestamp: DateTime.now(),
    );

    // Add to message manager
    widget.messageManager.addMessage(newMessage);

    // Add to local list
    setState(() {
      _messages.insert(0, newMessage);
    });

    // Clear text field
    _messageController.clear();

    // Show success message
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Message sent!'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  String _getTimeFormat(DateTime timestamp) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDay = DateTime(timestamp.year, timestamp.month, timestamp.day);

    if (messageDay == today) {
      return '${timestamp.hour}:${timestamp.minute.toString().padLeft(2, '0')}';
    } else if (messageDay == today.subtract(const Duration(days: 1))) {
      return 'Yesterday ${timestamp.hour}:${timestamp.minute.toString().padLeft(2, '0')}';
    } else {
      return '${timestamp.day}/${timestamp.month}/${timestamp.year} ${timestamp.hour}:${timestamp.minute.toString().padLeft(2, '0')}';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.otherUserName),
            const Text('Online', style: TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () {
              // More options
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.chat, size: 60, color: Colors.grey),
                        SizedBox(height: 10),
                        Text(
                          'No messages yet',
                          style: TextStyle(fontSize: 16, color: Colors.grey),
                        ),
                        SizedBox(height: 5),
                        Text(
                          'Start a conversation!',
                          style: TextStyle(fontSize: 14, color: Colors.grey),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    reverse: true,
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      final isMe = message.senderId == widget.currentUserId;

                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Align(
                          alignment: isMe
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            constraints: BoxConstraints(
                              maxWidth: MediaQuery.of(context).size.width * 0.7,
                            ),
                            child: Card(
                              color: isMe ? Colors.blue[50] : Colors.grey[100],
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      message.text,
                                      style: const TextStyle(fontSize: 14),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      _getTimeFormat(message.timestamp),
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: Colors.grey.shade300)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: InputDecoration(
                      hintText: 'Type your message...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  backgroundColor: Colors.blue,
                  child: IconButton(
                    icon: const Icon(Icons.send, color: Colors.white),
                    onPressed: _sendMessage,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ==============================================
// STUDENT HOME PAGE (UPDATED WITH AUTH) - FIXED VERSION
// ==============================================

class StudentHomePage extends StatefulWidget {
  const StudentHomePage({super.key});

  @override
  State<StudentHomePage> createState() => _StudentHomePageState();
}

class _StudentHomePageState extends State<StudentHomePage> {
  final ValueNotifier<int> _selectedIndex = ValueNotifier(0);
  final List<String> _selectedSubjects = ['Computer Science', 'Physics'];
  final List<Map<String, dynamic>> _exercises = [
    {
      'id': '1',
      'title': 'Machine Learning Problem Set',
      'subject': 'Computer Science',
      'date': '2 hours ago',
      'completed': false,
    },
    {
      'id': '2',
      'title': 'Quantum Mechanics Exercises',
      'subject': 'Physics',
      'date': '1 day ago',
      'completed': true,
    },
  ];

  // UPDATED: FILE PICKER STATE FOR STUDENT (SUPPORTS PDF & IMAGES)
  File? _selectedStudentFile;
  String? _selectedFileType;
  String? _selectedFileExtension;
  final ImagePicker _studentPicker = ImagePicker();

  // DATA MANAGER
  final PaperDataManager _dataManager = PaperDataManager();
  final MessageManager _messageManager = MessageManager();

  // AUTH MANAGER
  final AuthManager _authManager = AuthManager();
  Map<String, dynamic>? _currentUser;

  // UPDATED: FUNCTION TO PICK FILE FOR STUDENT (SUPPORTS PDF & IMAGES)
  Future<void> _pickStudentFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png'],
    );

    if (result != null && result.files.single.path != null) {
      setState(() {
        _selectedStudentFile = File(result.files.single.path!);
        _selectedFileExtension = result.files.single.extension;
        _selectedFileType = _getFileTypeFromExtension(_selectedFileExtension);
      });
    }
  }

  // FUNCTION TO PICK IMAGE (CAMERA/GALLERY)
  Future<void> _pickStudentImage(ImageSource source) async {
    final XFile? file = await _studentPicker.pickImage(
      source: source,
      imageQuality: 85,
    );

    if (file != null) {
      setState(() {
        _selectedStudentFile = File(file.path);
        _selectedFileExtension = 'jpg';
        _selectedFileType = 'IMAGE';
      });
    }
  }

  String _getFileTypeFromExtension(String? extension) {
    if (extension == null) return 'FILE';
    switch (extension.toLowerCase()) {
      case 'pdf':
        return 'PDF';
      case 'jpg':
      case 'jpeg':
      case 'png':
        return 'IMAGE';
      default:
        return 'FILE';
    }
  }

  IconData _getFileIcon(String? fileType) {
    switch (fileType?.toLowerCase()) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'image':
        return Icons.image;
      default:
        return Icons.insert_drive_file;
    }
  }

  Color _getFileColor(String? fileType) {
    switch (fileType?.toLowerCase()) {
      case 'pdf':
        return Colors.red;
      case 'image':
        return Colors.green;
      default:
        return Colors.grey;
    }
  }

  // FIXED: OPEN FILE VIEWER FOR STUDENT - REMOVED CONTEXT PARAMETER
  void _openFileViewer(String paperId) {
    final file = _dataManager.getPaperFile(paperId);
    final paper = _dataManager.allPapers.firstWhere(
      (paper) => paper['id'] == paperId,
      orElse: () => {'title': 'Unknown Paper'},
    );
    final fileName = paper['title'];

    if (file == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('File not found'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    // Check if student can view this file
    final canView =
        _dataManager.isPaperFilePdf(paperId) ||
        _dataManager.isPaperFileImage(paperId);

    if (!canView) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('File type not supported for preview'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    // Check if paper is approved (public) or belongs to student
    final isPublic = paper['isPublic'] == true;
    final isOwnPaper =
        paper['studentId'] == _currentUser?['studentId'] ||
        paper['studentId'] == 'STU001';

    if (!isPublic && !isOwnPaper) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You do not have permission to view this file'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    if (_dataManager.isPaperFilePdf(paperId)) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) =>
              PDFViewerScreen(pdfFile: file, fileName: fileName),
        ),
      );
    } else if (_dataManager.isPaperFileImage(paperId)) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) =>
              ImageViewerScreen(imageFile: file, fileName: fileName),
        ),
      );
    }
  }

  // GET UNREAD MESSAGES COUNT FOR STUDENT
  int getUnreadMessagesCount() {
    return _messageManager.getUnreadMessageCount(
      _currentUser?['studentId'] ?? 'STU001',
    );
  }

  @override
  void initState() {
    super.initState();
    _loadCurrentUser();
  }

  Future<void> _loadCurrentUser() async {
    _currentUser = await _authManager.getCurrentUser();
    setState(() {});
  }

  @override
  void dispose() {
    _selectedIndex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // FIXED: GET USER'S PENDING SUBMISSIONS WITH TYPE CAST
    final userPendingSubmissions = _currentUser != null
        ? _dataManager.allPapers
              .where(
                (paper) =>
                    paper['status'] == 'pending' &&
                    paper['studentId'] == _currentUser!['studentId'],
              )
              .toList()
              .cast<Map<String, dynamic>>() // ADDED TYPE CAST
        : <Map<String, dynamic>>[]; // SPECIFIED TYPE FOR EMPTY LIST

    // GET PUBLIC PAPERS (APPROVED PAPERS)
    final publicPapers = _dataManager.getPublicPapers();

    // GET UNREAD MESSAGES COUNT
    final unreadMessagesCount = getUnreadMessagesCount();

    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        systemOverlayStyle: SystemUiOverlayStyle.dark,
        backgroundColor: Colors.white,
        elevation: 0,
        title: Row(
          children: [
            CircleAvatar(
              backgroundColor: Colors.blue,
              backgroundImage:
                  _currentUser != null &&
                      _currentUser!['profilePicture'] != null &&
                      _currentUser!['profilePicture'].isNotEmpty
                  ? FileImage(File(_currentUser!['profilePicture']))
                  : null,
              child:
                  _currentUser == null ||
                      _currentUser!['profilePicture'] == null ||
                      _currentUser!['profilePicture'].isEmpty
                  ? const Icon(Icons.person, color: Colors.white, size: 24)
                  : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'Welcome back,',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _currentUser?['fullName']?.split(' ').first ?? 'Student',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.blue[800],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          // MESSAGES ICON WITH BADGE
          Stack(
            children: [
              IconButton(
                icon: const Icon(
                  Icons.chat_bubble_outline,
                  color: Colors.grey,
                  size: 22,
                ),
                onPressed: _openMessages,
              ),
              if (unreadMessagesCount > 0)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                      color: Colors.blue,
                      shape: BoxShape.circle,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 14,
                      minHeight: 14,
                    ),
                    child: Text(
                      unreadMessagesCount.toString(),
                      style: const TextStyle(color: Colors.white, fontSize: 8),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
          IconButton(
            icon: Stack(
              children: [
                const Icon(
                  Icons.notifications_none,
                  color: Colors.grey,
                  size: 22,
                ),
                // SHOW BADGE IF USER HAS PENDING PAPERS
                if (userPendingSubmissions.isNotEmpty)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                        color: Colors.orange,
                        shape: BoxShape.circle,
                      ),
                      constraints: const BoxConstraints(
                        minWidth: 14,
                        minHeight: 14,
                      ),
                      child: Text(
                        userPendingSubmissions.length.toString(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 8,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
            onPressed: () {
              _showNotifications(context);
            },
          ),
          PopupMenuButton(
            icon: const Icon(Icons.more_vert, color: Colors.grey),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout, color: Colors.red, size: 20),
                    SizedBox(width: 10),
                    Text('Logout'),
                  ],
                ),
              ),
            ],
            onSelected: (value) {
              if (value == 'logout') {
                _logout();
              }
            },
          ),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: _selectedIndex,
        builder: (context, index, child) {
          return _buildBody(index, userPendingSubmissions, publicPapers);
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showUploadDialog,
        icon: const Icon(Icons.upload, size: 20),
        label: const Text('Upload Paper', style: TextStyle(fontSize: 14)),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
      ),
      bottomNavigationBar: ValueListenableBuilder<int>(
        valueListenable: _selectedIndex,
        builder: (context, index, child) {
          return BottomNavigationBar(
            currentIndex: index,
            onTap: (newIndex) => _selectedIndex.value = newIndex,
            type: BottomNavigationBarType.fixed,
            selectedItemColor: Colors.blue,
            unselectedItemColor: Colors.grey,
            selectedFontSize: 12,
            unselectedFontSize: 12,
            items: const [
              BottomNavigationBarItem(
                icon: Icon(Icons.dashboard, size: 22),
                label: 'Dashboard',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.library_books, size: 22),
                label: 'Public Papers',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.auto_awesome, size: 22),
                label: 'AI Exercises',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.person_outline, size: 22),
                label: 'Profile',
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _logout() async {
    try {
      await _authManager.logout();

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const WelcomePage()),
        (route) => false,
      );

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Logged out successfully'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error logging out: $e'),
          duration: const Duration(seconds: 3),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget _buildBody(
    int index,
    List<Map<String, dynamic>> pendingSubmissions,
    List<Map<String, dynamic>> publicPapers,
  ) {
    switch (index) {
      case 0:
        return _buildDashboard(pendingSubmissions, publicPapers);
      case 1:
        return _buildPublicPapersList(publicPapers);
      case 2:
        return _buildAIExercises();
      case 3:
        return const StudentProfilePage();
      default:
        return _buildDashboard(pendingSubmissions, publicPapers);
    }
  }

  Widget _buildDashboard(
    List<Map<String, dynamic>> pendingSubmissions,
    List<Map<String, dynamic>> publicPapers,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildQuickStats(pendingSubmissions, publicPapers),
          const SizedBox(height: 24),
          if (pendingSubmissions.isNotEmpty) ...[
            _buildPendingSubmissions(pendingSubmissions),
            const SizedBox(height: 24),
          ],
          _buildPublicPapersPreview(publicPapers),
          const SizedBox(height: 24),
          _buildAIExerciseCard(),
        ],
      ),
    );
  }

  Widget _buildQuickStats(
    List<Map<String, dynamic>> pendingSubmissions,
    List<Map<String, dynamic>> publicPapers,
  ) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Wrap(
        spacing: 20,
        runSpacing: 20,
        alignment: WrapAlignment.spaceAround,
        children: [
          _buildStatItem(
            Icons.pending,
            '${pendingSubmissions.length}',
            'Pending',
            Colors.orange,
          ),
          _buildStatItem(
            Icons.check_circle,
            '${publicPapers.length}',
            'Approved',
            Colors.green,
          ),
          _buildStatItem(
            Icons.upload_file,
            '${pendingSubmissions.length + publicPapers.where((p) => p['studentId'] == _currentUser?['studentId']).length}',
            'My Uploads',
            Colors.blue,
          ),
          _buildStatItem(
            Icons.public,
            '${publicPapers.length}',
            'Public Papers',
            Colors.purple,
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(
    IconData icon,
    String value,
    String label,
    Color color,
  ) {
    return Column(
      children: [
        Icon(icon, color: color, size: 28),
        const SizedBox(height: 8),
        Text(
          value,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }

  Widget _buildPendingSubmissions(
    List<Map<String, dynamic>> pendingSubmissions,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'My Pending Submissions',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        ...pendingSubmissions.map(
          (paper) => _buildPaperCard(paper, isPending: true),
        ),
      ],
    );
  }

  Widget _buildPublicPapersPreview(List<Map<String, dynamic>> publicPapers) {
    final recentPapers = publicPapers.take(3).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Recent Public Papers',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            TextButton(
              onPressed: () => _selectedIndex.value = 1,
              child: const Text('View All'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (recentPapers.isEmpty)
          const Center(
            child: Text(
              'No public papers available yet',
              style: TextStyle(color: Colors.grey),
            ),
          )
        else
          ...recentPapers.map((paper) => _buildPaperCard(paper)),
      ],
    );
  }

  // FIXED: _buildPaperCard method with corrected _openFileViewer call
  Widget _buildPaperCard(Map<String, dynamic> paper, {bool isPending = false}) {
    final hasFile = _dataManager.paperHasFile(paper['id']);
    final fileType = _dataManager.getPaperFileType(paper['id']);
    final icon = _getFileIcon(fileType);
    final color = _getFileColor(fileType);

    return GestureDetector(
      onTap: () {
        _showPaperDetails(paper);
      },
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: ListTile(
          contentPadding: const EdgeInsets.all(16),
          leading: GestureDetector(
            onTap: () {
              if (hasFile) {
                _openFileViewer(paper['id']);
              }
            },
            child: Stack(
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color, size: 24),
                ),
                if (hasFile && _dataManager.isPaperFileImage(paper['id']))
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.image,
                        size: 12,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          title: Text(
            paper['title'],
            style: const TextStyle(fontWeight: FontWeight.bold),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Subject: ${paper['subject']}'),
              const SizedBox(height: 4),
              Text(
                'By: ${paper['studentName']} • ${paper['date']}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              if (paper['grade'] != null)
                Text(
                  'Grade: ${paper['grade']}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.green[700],
                    fontWeight: FontWeight.bold,
                  ),
                ),
            ],
          ),
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: isPending ? Colors.orange[100] : Colors.green[100],
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              isPending ? 'Pending' : 'Public',
              style: TextStyle(
                color: isPending ? Colors.orange[800] : Colors.green[800],
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAIExerciseCard() {
    return GestureDetector(
      onTap: () => _selectedIndex.value = 2,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1565C0), Color(0xFF4A148C)],
          ),
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'AI Exercise Generator',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Get personalized exercises based on your selected subjects',
                    style: TextStyle(fontSize: 14, color: Colors.white70),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: () => _selectedIndex.value = 2,
                    icon: const Icon(Icons.auto_awesome, size: 16),
                    label: const Text('Generate Exercises'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFF1565C0),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            const Icon(Icons.auto_awesome, size: 50, color: Colors.white),
          ],
        ),
      ),
    );
  }

  Widget _buildPublicPapersList(List<Map<String, dynamic>> publicPapers) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: publicPapers.length,
      itemBuilder: (context, index) {
        final paper = publicPapers[index];
        final hasFile = _dataManager.paperHasFile(paper['id']);
        final fileType = _dataManager.getPaperFileType(paper['id']);
        final icon = _getFileIcon(fileType);
        final color = _getFileColor(fileType);

        return GestureDetector(
          onTap: () {
            _showPaperDetails(paper);
          },
          child: Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: GestureDetector(
                onTap: () {
                  if (hasFile) {
                    _openFileViewer(paper['id']);
                  }
                },
                child: Stack(
                  children: [
                    Icon(icon, color: color, size: 35),
                    if (hasFile && _dataManager.isPaperFileImage(paper['id']))
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.image,
                            size: 12,
                            color: Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              title: Text(
                paper['title'],
                style: const TextStyle(fontWeight: FontWeight.bold),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Subject: ${paper['subject']}'),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    children: [
                      if (paper['grade'] != null)
                        Chip(
                          label: Text('Grade: ${paper['grade']}'),
                          backgroundColor: Colors.green[50],
                          labelStyle: const TextStyle(fontSize: 12),
                        ),
                      Chip(
                        label: const Text('Public'),
                        backgroundColor: Colors.blue[50],
                        labelStyle: const TextStyle(fontSize: 12),
                      ),
                      if (hasFile)
                        Chip(
                          label: Text(fileType ?? 'File'),
                          backgroundColor: color.withOpacity(0.2),
                          labelStyle: TextStyle(fontSize: 12, color: color),
                        ),
                      if (paper['uploadedBy'] == 'admin')
                        Chip(
                          label: const Text('Admin'),
                          backgroundColor: Colors.orange[50],
                          labelStyle: const TextStyle(fontSize: 12),
                        ),
                    ],
                  ),
                ],
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasFile)
                    IconButton(
                      icon: const Icon(Icons.visibility, size: 22),
                      onPressed: () {
                        _openFileViewer(paper['id']);
                      },
                      tooltip: 'View File',
                    ),
                  IconButton(
                    icon: const Icon(Icons.download, size: 22),
                    onPressed: () {
                      _downloadPaper(paper);
                    },
                    tooltip: 'Download',
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildAIExercises() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'AI Exercise Generator',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Select subjects to generate personalized exercises',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 24),
          _buildSubjectSelection(),
          const SizedBox(height: 24),
          _buildGeneratedExercises(),
        ],
      ),
    );
  }

  Widget _buildSubjectSelection() {
    final subjects = [
      'Computer Science',
      'Mathematics',
      'Physics',
      'Economics',
      'Literature',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Select Subjects',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: subjects.map((subject) {
            final isSelected = _selectedSubjects.contains(subject);
            return FilterChip(
              label: Text(subject),
              selected: isSelected,
              onSelected: (bool selected) {
                setState(() {
                  if (selected) {
                    _selectedSubjects.add(subject);
                  } else {
                    _selectedSubjects.remove(subject);
                  }
                });
              },
              selectedColor: Colors.blue[100],
            );
          }).toList(),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () {
              if (_selectedSubjects.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Please select at least one subject'),
                    duration: Duration(seconds: 2),
                  ),
                );
                return;
              }

              _generateExercises();
            },
            icon: const Icon(Icons.auto_awesome),
            label: const Text('Generate New Exercises'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGeneratedExercises() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Recent Exercises',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        ..._exercises.map((exercise) {
          return GestureDetector(
            onTap: () {
              _showExerciseDetails(exercise);
            },
            child: Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: ListTile(
                contentPadding: const EdgeInsets.all(16),
                leading: CircleAvatar(
                  backgroundColor: exercise['completed']
                      ? Colors.green[100]
                      : Colors.blue[100],
                  child: Icon(
                    exercise['completed'] ? Icons.check : Icons.quiz,
                    color: exercise['completed'] ? Colors.green : Colors.blue,
                  ),
                ),
                title: Text(exercise['title']),
                subtitle: Text(
                  '${exercise['subject']} • Generated ${exercise['date']}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!exercise['completed'])
                      IconButton(
                        icon: const Icon(Icons.check, size: 20),
                        onPressed: () {
                          _markExerciseCompleted(exercise['id']);
                        },
                        tooltip: 'Mark as completed',
                      ),
                    IconButton(
                      icon: const Icon(Icons.download, size: 20),
                      onPressed: () {
                        _downloadExercise(exercise);
                      },
                      tooltip: 'Download',
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ],
    );
  }

  void _showUploadDialog() {
    final titleController = TextEditingController();
    final subjectController = TextEditingController();
    final descriptionController = TextEditingController();
    String? selectedSubject = 'Computer Science';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return SingleChildScrollView(
              child: Container(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom,
                  left: 24,
                  right: 24,
                  top: 24,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Upload Document',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text('Select subject:'),
                    DropdownButtonFormField<String>(
                      initialValue: selectedSubject,
                      items: const [
                        DropdownMenuItem(
                          value: 'Computer Science',
                          child: Text('Computer Science'),
                        ),
                        DropdownMenuItem(
                          value: 'Mathematics',
                          child: Text('Mathematics'),
                        ),
                        DropdownMenuItem(
                          value: 'Physics',
                          child: Text('Physics'),
                        ),
                        DropdownMenuItem(
                          value: 'Economics',
                          child: Text('Economics'),
                        ),
                      ],
                      onChanged: (value) {
                        setState(() {
                          selectedSubject = value;
                        });
                      },
                      decoration: const InputDecoration(
                        hintText: 'Choose subject',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: titleController,
                      decoration: const InputDecoration(
                        labelText: 'Document Title',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: descriptionController,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Description/Abstract (Optional)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // UPDATED: FILE PICKER SECTION FOR PDF & IMAGES
                    Container(
                      width: double.infinity,
                      height: 200,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: _selectedStudentFile == null
                          ? const Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.cloud_upload,
                                    size: 48,
                                    color: Colors.grey,
                                  ),
                                  SizedBox(height: 8),
                                  Text('No file selected'),
                                  Text(
                                    'Select a PDF or image to upload',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey,
                                    ),
                                  ),
                                  SizedBox(height: 8),
                                  Text(
                                    'Supports: PDF, JPG, PNG',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : Column(
                              children: [
                                Expanded(
                                  child: _selectedFileType == 'IMAGE'
                                      ? Image.file(
                                          _selectedStudentFile!,
                                          fit: BoxFit.cover,
                                        )
                                      : Container(
                                          color: Colors.grey[100],
                                          child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Icon(
                                                _getFileIcon(_selectedFileType),
                                                size: 60,
                                                color: _getFileColor(
                                                  _selectedFileType,
                                                ),
                                              ),
                                              const SizedBox(height: 10),
                                              Text(
                                                '${_selectedFileType ?? 'File'} Document',
                                                style: const TextStyle(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                              const SizedBox(height: 5),
                                              Text(
                                                _selectedStudentFile!.path
                                                    .split('/')
                                                    .last,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ],
                                          ),
                                        ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.all(8.0),
                                  child: Text(
                                    _selectedStudentFile!.path.split('/').last,
                                    style: const TextStyle(fontSize: 12),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                    ),
                    const SizedBox(height: 12),

                    // UPDATED: FILE SELECTION BUTTONS
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        ElevatedButton.icon(
                          onPressed: () => _pickStudentFile(),
                          icon: const Icon(Icons.insert_drive_file),
                          label: const Text('Browse Files'),
                        ),
                        ElevatedButton.icon(
                          onPressed: () =>
                              _pickStudentImage(ImageSource.camera),
                          icon: const Icon(Icons.camera_alt),
                          label: const Text('Camera'),
                        ),
                        ElevatedButton.icon(
                          onPressed: () =>
                              _pickStudentImage(ImageSource.gallery),
                          icon: const Icon(Icons.photo),
                          label: const Text('Gallery'),
                        ),
                      ],
                    ),

                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () {
                              setState(() {
                                _selectedStudentFile = null;
                                _selectedFileType = null;
                                _selectedFileExtension = null;
                              });
                              Navigator.pop(context);
                            },
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () {
                              if (titleController.text.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Please enter a title'),
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                                return;
                              }

                              if (_selectedStudentFile == null) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Please select a file'),
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                                return;
                              }

                              // CREATE NEW PAPER WITH PENDING STATUS
                              final newPaper = {
                                'id':
                                    'STU${DateTime.now().millisecondsSinceEpoch}',
                                'title': titleController.text,
                                'subject': selectedSubject!,
                                'fileType': _selectedFileType ?? 'FILE',
                                'description': descriptionController.text,
                                'fileSize':
                                    '${_selectedStudentFile!.lengthSync() ~/ 1024}KB',
                                'date': DateTime.now().toString().split(' ')[0],
                                'studentId':
                                    _currentUser?['studentId'] ?? 'STU001',
                                'studentName':
                                    _currentUser?['fullName'] ??
                                    'Current Student',
                                'abstract':
                                    descriptionController.text.isNotEmpty
                                    ? descriptionController.text
                                    : 'Paper submitted by student',
                                'status': 'pending',
                                'uploadedBy': 'student',
                                'isPublic': false,
                                'hasFile': true,
                                'fileExtension': _selectedFileExtension != null
                                    ? '.$_selectedFileExtension'
                                    : '.file',
                              };

                              // ADD TO GLOBAL DATA MANAGER WITH FILE
                              _dataManager.addPaper(
                                newPaper,
                                file: _selectedStudentFile,
                                fileType: _selectedFileType,
                              );

                              // ADD NOTIFICATION FOR ADMIN
                              _dataManager.addNotification(
                                'New Paper Submission',
                                'Student submitted "${titleController.text}" for review',
                              );

                              // SEND MESSAGE TO ADMIN
                              _messageManager.addMessage(
                                Message(
                                  id: 'MSG${DateTime.now().millisecondsSinceEpoch}',
                                  senderId:
                                      _currentUser?['studentId'] ?? 'STU001',
                                  senderName:
                                      _currentUser?['fullName'] ?? 'Student',
                                  receiverId: 'ADMIN',
                                  text:
                                      'I have submitted a new paper: "${titleController.text}" for review.',
                                  timestamp: DateTime.now(),
                                ),
                              );

                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Paper submitted successfully! It will be reviewed by admin.',
                                  ),
                                  duration: Duration(seconds: 2),
                                ),
                              );

                              // Reset file selection
                              setState(() {
                                _selectedStudentFile = null;
                                _selectedFileType = null;
                                _selectedFileExtension = null;
                              });

                              // Update UI
                              setState(() {});
                            },
                            child: const Text('Submit for Review'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _openMessages() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          currentUserId: _currentUser?['studentId'] ?? 'STU001',
          currentUserName: _currentUser?['fullName'] ?? 'Student',
          otherUserId: 'ADMIN',
          otherUserName: 'Admin Fahdil',
          messageManager: _messageManager,
        ),
      ),
    );
  }

  void _showNotifications(BuildContext context) {
    // FIXED: Added type cast for userPendingSubmissions
    final userPendingSubmissions = _currentUser != null
        ? _dataManager.allPapers
              .where(
                (paper) =>
                    paper['status'] == 'pending' &&
                    paper['studentId'] == _currentUser!['studentId'],
              )
              .toList()
              .cast<Map<String, dynamic>>()
        : <Map<String, dynamic>>[];

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(20),
          height: MediaQuery.of(context).size.height * 0.5,
          child: Column(
            children: [
              const Text(
                'My Submissions Status',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: userPendingSubmissions.isEmpty
                    ? const Center(
                        child: Text(
                          'No pending submissions',
                          style: TextStyle(fontSize: 16, color: Colors.grey),
                        ),
                      )
                    : ListView(
                        children: userPendingSubmissions.map((paper) {
                          return ListTile(
                            leading: const Icon(
                              Icons.pending,
                              color: Colors.orange,
                            ),
                            title: Text(paper['title']),
                            subtitle: Text('Submitted: ${paper['date']}'),
                            trailing: Chip(
                              label: const Text('Pending'),
                              backgroundColor: Colors.orange[100],
                            ),
                          );
                        }).toList(),
                      ),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  _showUploadDialog();
                },
                child: const Text('Submit New Paper'),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showPaperDetails(Map<String, dynamic> paper) {
    final hasFile = _dataManager.paperHasFile(paper['id']);
    final file = _dataManager.getPaperFile(paper['id']);
    final isImage = _dataManager.isPaperFileImage(paper['id']);
    final fileType = _dataManager.getPaperFileType(paper['id']);

    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          insetPadding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          paper['title'],
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),

                  // FILE PREVIEW SECTION - Students can see approved paper files
                  if (hasFile && file != null && paper['status'] == 'approved')
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Uploaded File Content:',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 10),

                        if (isImage)
                          GestureDetector(
                            onTap: () {
                              Navigator.pop(context);
                              _openFileViewer(paper['id']);
                            },
                            child: Container(
                              width: double.infinity,
                              height: 350,
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Stack(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.file(
                                      file,
                                      fit: BoxFit.contain,
                                      errorBuilder:
                                          (context, error, stackTrace) {
                                            return const Center(
                                              child: Column(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  Icon(
                                                    Icons.broken_image,
                                                    size: 60,
                                                    color: Colors.grey,
                                                  ),
                                                  SizedBox(height: 10),
                                                  Text('Unable to load image'),
                                                ],
                                              ),
                                            );
                                          },
                                    ),
                                  ),
                                  Positioned(
                                    bottom: 10,
                                    right: 10,
                                    child: Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withOpacity(0.7),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: const Row(
                                        children: [
                                          Icon(
                                            Icons.fullscreen,
                                            size: 16,
                                            color: Colors.white,
                                          ),
                                          SizedBox(width: 4),
                                          Text(
                                            'Tap to view fullscreen',
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else
                          GestureDetector(
                            onTap: () {
                              Navigator.pop(context);
                              _openFileViewer(paper['id']);
                            },
                            child: Container(
                              width: double.infinity,
                              height: 250,
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey),
                                borderRadius: BorderRadius.circular(8),
                                color: Colors.grey[100],
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    _getFileIcon(fileType),
                                    size: 80,
                                    color: _getFileColor(fileType),
                                  ),
                                  const SizedBox(height: 15),
                                  Text(
                                    '${fileType ?? 'Document'} File',
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    file.path.split('/').last,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      color: Colors.grey,
                                    ),
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 20),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: _getFileColor(fileType),
                                      borderRadius: BorderRadius.circular(25),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.visibility,
                                          size: 16,
                                          color: Colors.white,
                                        ),
                                        SizedBox(width: 6),
                                        Text(
                                          'View Full Document',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        const SizedBox(height: 20),
                      ],
                    ),

                  // FOR PENDING PAPERS, SHOW UPLOADED FILE (ONLY OWNER CAN SEE)
                  if (hasFile &&
                      file != null &&
                      paper['status'] == 'pending' &&
                      paper['studentId'] == _currentUser?['studentId'])
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Your Uploaded File:',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.orange,
                          ),
                        ),
                        const SizedBox(height: 10),

                        if (isImage)
                          GestureDetector(
                            onTap: () {
                              Navigator.pop(context);
                              _openFileViewer(paper['id']);
                            },
                            child: Container(
                              width: double.infinity,
                              height: 300,
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.orange),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Stack(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.file(
                                      file,
                                      fit: BoxFit.cover,
                                      errorBuilder:
                                          (context, error, stackTrace) {
                                            return const Center(
                                              child: Column(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  Icon(
                                                    Icons.broken_image,
                                                    size: 60,
                                                    color: Colors.grey,
                                                  ),
                                                  SizedBox(height: 10),
                                                  Text('Unable to load image'),
                                                ],
                                              ),
                                            );
                                          },
                                    ),
                                  ),
                                  Positioned(
                                    bottom: 10,
                                    right: 10,
                                    child: Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: Colors.orange.withOpacity(0.9),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: const Row(
                                        children: [
                                          Icon(
                                            Icons.fullscreen,
                                            size: 16,
                                            color: Colors.white,
                                          ),
                                          SizedBox(width: 4),
                                          Text(
                                            'Tap to view',
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else
                          GestureDetector(
                            onTap: () {
                              Navigator.pop(context);
                              _openFileViewer(paper['id']);
                            },
                            child: Container(
                              width: double.infinity,
                              height: 200,
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.orange),
                                borderRadius: BorderRadius.circular(8),
                                color: Colors.orange[50],
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    _getFileIcon(fileType),
                                    size: 60,
                                    color: Colors.orange,
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    '${fileType ?? 'File'} Document',
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.orange,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    file.path.split('/').last,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.orange,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 15),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.orange,
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.visibility,
                                          size: 14,
                                          color: Colors.white,
                                        ),
                                        SizedBox(width: 4),
                                        Text(
                                          'View Your Submission',
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        const SizedBox(height: 10),
                        const Text(
                          'This file is only visible to you until the paper is approved',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.orange,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
                    ),

                  // Paper Details
                  const Text(
                    'Paper Details:',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),

                  _buildDetailRow('By:', paper['studentName']),
                  _buildDetailRow('Student ID:', paper['studentId']),
                  _buildDetailRow('Subject:', paper['subject']),
                  _buildDetailRow('Submitted:', paper['date']),
                  _buildDetailRow('Status:', paper['status']),
                  _buildDetailRow('File Size:', paper['fileSize']),
                  _buildDetailRow('File Type:', paper['fileType']),

                  if (paper['grade'] != null)
                    _buildDetailRow('Grade:', paper['grade']),

                  if (paper['feedback'] != null)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 10),
                        const Text(
                          'Feedback:',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(paper['feedback']),
                      ],
                    ),

                  const SizedBox(height: 20),

                  const Text(
                    'Abstract:',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  Text(paper['abstract'] ?? 'No abstract available'),

                  const SizedBox(height: 20),

                  if (paper['isPublic'] == true)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.green[50],
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.public, color: Colors.green, size: 16),
                          SizedBox(width: 8),
                          Text(
                            'This paper is publicly available',
                            style: TextStyle(fontSize: 12, color: Colors.green),
                          ),
                        ],
                      ),
                    ),

                  const SizedBox(height: 30),

                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Close'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      if (hasFile)
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () {
                              _openFileViewer(paper['id']);
                            },
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.visibility, size: 16),
                                SizedBox(width: 5),
                                Text('View File'),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w500,
                color: Colors.grey,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  void _downloadPaper(Map<String, dynamic> paper) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Downloading ${paper['title']}...'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _generateExercises() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Generating exercises...'),
        duration: Duration(seconds: 2),
      ),
    );

    // Simulate API call
    Future.delayed(const Duration(seconds: 2), () {
      setState(() {
        _exercises.insert(0, {
          'id': '${_exercises.length + 1}',
          'title': 'New ${_selectedSubjects.first} Exercise',
          'subject': _selectedSubjects.first,
          'date': 'Just now',
          'completed': false,
        });
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Exercises generated successfully!'),
          duration: Duration(seconds: 2),
        ),
      );
    });
  }

  void _showExerciseDetails(Map<String, dynamic> exercise) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(exercise['title']),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Subject: ${exercise['subject']}'),
              const SizedBox(height: 10),
              Text('Generated: ${exercise['date']}'),
              const SizedBox(height: 10),
              const Text('Exercise Content:'),
              const SizedBox(height: 10),
              const Text(
                '1. Solve the following problems:\n2. Explain the concepts:\n3. Apply to real-world scenarios:',
                style: TextStyle(fontSize: 14),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
            ElevatedButton(
              onPressed: () {
                _downloadExercise(exercise);
                Navigator.pop(context);
              },
              child: const Text('Download'),
            ),
          ],
        );
      },
    );
  }

  void _markExerciseCompleted(String id) {
    setState(() {
      final index = _exercises.indexWhere((e) => e['id'] == id);
      if (index != -1) {
        _exercises[index]['completed'] = true;
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Exercise marked as completed!'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _downloadExercise(Map<String, dynamic> exercise) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Downloading ${exercise['title']}...'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showSubmissionHistory(BuildContext context) {
    // FIXED: Added type cast for userPapers
    final userPapers = _dataManager.allPapers
        .where((paper) => paper['studentId'] == _currentUser?['studentId'])
        .toList()
        .cast<Map<String, dynamic>>();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('My Submission History'),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: ListView(
              children: [
                if (userPapers.isEmpty)
                  const Center(
                    child: Text(
                      'No submissions yet',
                      style: TextStyle(fontSize: 16, color: Colors.grey),
                    ),
                  )
                else
                  ...userPapers.map(
                    (paper) => ListTile(
                      leading: Icon(
                        paper['status'] == 'approved'
                            ? Icons.check_circle
                            : Icons.pending,
                        color: paper['status'] == 'approved'
                            ? Colors.green
                            : Colors.orange,
                      ),
                      title: Text(paper['title']),
                      subtitle: Text(
                        '${paper['date']} • ${paper['status']} • ${paper['grade'] ?? ''}',
                      ),
                      trailing: paper['hasFile'] == true
                          ? IconButton(
                              icon: const Icon(Icons.visibility, size: 20),
                              onPressed: () {
                                Navigator.pop(context);
                                _openFileViewer(paper['id']);
                              },
                            )
                          : null,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  void _showHelpSupport(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Help & Support'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.help),
                title: const Text('FAQs'),
                onTap: () {},
              ),
              ListTile(
                leading: const Icon(Icons.contact_support),
                title: const Text('Contact Support'),
                onTap: () {},
              ),
              ListTile(
                leading: const Icon(Icons.feedback),
                title: const Text('Send Feedback'),
                onTap: () {},
              ),
              ListTile(
                leading: const Icon(Icons.privacy_tip),
                title: const Text('Privacy Policy'),
                onTap: () {},
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  IconData _getSubjectIcon(String subject) {
    switch (subject) {
      case 'Computer Science':
        return Icons.computer;
      case 'Physics':
        return Icons.science;
      case 'Economics':
        return Icons.bar_chart;
      default:
        return Icons.book;
    }
  }
}
