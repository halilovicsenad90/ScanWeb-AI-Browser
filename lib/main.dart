import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';

// NOVI PAKETI ZA MARKDOWN I KOD
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

// OVO SU NOVI PAKETI ZA SERVER I PROZOR
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

Process? backendProcess;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicijalizacija menadžera prozora (da mognemo ugasiti server kad ugasimo app)
  await windowManager.ensureInitialized();
  WindowOptions windowOptions = const WindowOptions(
    size: Size(1200, 800),
    center: true,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  // Pokreni lokalni Python server
  await pokreniBackend();

  runApp(const AIMultiBrowserApp());
}

Future<void> pokreniBackend() async {
  try {
    // Pronalazi tačan folder gdje je aplikacija instalirana/raspakovana
    String executableDir = File(Platform.resolvedExecutable).parent.path;
    String backendPath = Platform.isWindows 
        ? p.join(executableDir, 'server.exe') 
        : p.join(executableDir, 'server');

    if (File(backendPath).existsSync()) {
      // Ako fajl postoji, upali ga u pozadini
      backendProcess = await Process.start(backendPath, []);
      print("Backend USPJEŠNO pokrenut na: $backendPath");
    } else {
      print("GREŠKA: Backend fajl nije pronađen pored aplikacije na: $backendPath");
    }
  } catch (e) {
    print("Greška pri pokretanju backenda: $e");
  }
}

// Mijenjamo StatelessWidget u StatefulWidget da bismo pratili gašenje prozora
class AIMultiBrowserApp extends StatefulWidget {
  const AIMultiBrowserApp({super.key});

  @override
  State<AIMultiBrowserApp> createState() => _AIMultiBrowserAppState();
}

class _AIMultiBrowserAppState extends State<AIMultiBrowserApp> with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() {
    // KLJUČNO: Ubij proces Python servera kada korisnik "iksa" aplikaciju
    backendProcess?.kill();
    super.onWindowClose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ScanWeb AI Multi-Browser',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F172A), 
        cardColor: const Color(0xFF1E293B),
        colorScheme: const ColorScheme.dark(
          primary: Colors.cyanAccent,
          secondary: Colors.cyanAccent,
        ),
      ),
      home: const MainScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with SingleTickerProviderStateMixin {
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ScrollController _modelsScrollController = ScrollController();
  
  late AnimationController _blinkController;
  late Animation<double> _blinkAnimation;

  List<Map<String, dynamic>> _messages = [];
  List<Map<String, dynamic>> _chats = [];
  String _currentSessionId = "default_chat";
  String _currentChatTitle = "Novi Razgovor";

  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _modelController = TextEditingController();
  final TextEditingController _tokenLimitController = TextEditingController(); 
  String _selectedProvider = 'Groq';
  
  bool _isSettingsExpanded = false; 
  String? _base64Image;

  bool _isDebateRunning = false;
  bool _showContinueDebateButton = false;
  
  bool _isEnglish = false;
  String _lang(String ba, String en) => _isEnglish ? en : ba;

  final List<Map<String, dynamic>> _aiModels = [];
  final List<String> _providers = ['Google Gemini', 'OpenAI', 'Anthropic', 'Groq', 'Lokalni (Ollama)', 'OpenRouter'];

  @override
  void initState() {
    super.initState();
    _blinkController = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat(reverse: true);
    _blinkAnimation = Tween<double>(begin: 0.2, end: 1.0).animate(_blinkController);
    _loadSavedModels();
    _initSession();
  }

  @override
  void dispose() {
    _blinkController.dispose();
    super.dispose();
  }

  Future<void> _initSession() async {
    await _fetchChats();
    if (_chats.isNotEmpty) {
      await _switchChat(_chats[0]['session_id'], _chats[0]['title']);
    } else {
      await _createNewChat();
    }
  }

  Future<void> _fetchChats() async {
    try {
      final response = await http.get(Uri.parse('http://127.0.0.1:8000/chats'));
      if (response.statusCode == 200) {
        var data = jsonDecode(response.body);
        setState(() { _chats = List<Map<String, dynamic>>.from(data['chats']); });
      }
    } catch (e) {}
  }

  Future<void> _createNewChat() async {
    String newSessionId = "chat_${DateTime.now().millisecondsSinceEpoch}";
    String defaultTitle = _lang("Razgovor", "Conversation") + " ${(_chats.length + 1)}";
    setState(() {
      _currentSessionId = newSessionId; _currentChatTitle = defaultTitle; _messages.clear(); _showContinueDebateButton = false;
    });
    await _fetchChats();
  }

  Future<void> _switchChat(String sessionId, String title) async {
    setState(() { _currentSessionId = sessionId; _currentChatTitle = title; _showContinueDebateButton = false; });
    try {
      final response = await http.get(Uri.parse('http://127.0.0.1:8000/history/$sessionId'));
      if (response.statusCode == 200) {
        var data = jsonDecode(response.body);
        setState(() { _messages = List<Map<String, dynamic>>.from(data['messages']); });
        _scrollToBottom();
      }
    } catch (e) {}
  }

  Future<void> _renameChat(String sessionId) async {
    TextEditingController renameController = TextEditingController(text: _currentChatTitle);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: Text(_lang("Preimenuj razgovor", "Rename Conversation")),
        content: TextField(controller: renameController, decoration: const InputDecoration(border: OutlineInputBorder())),
        actions: [
          TextButton(child: Text(_lang("Odustani", "Cancel")), onPressed: () => Navigator.pop(context)),
          ElevatedButton(
            child: Text(_lang("Sačuvaj", "Save"), style: const TextStyle(color: Colors.black)),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.cyanAccent),
            onPressed: () async {
              String newTitle = renameController.text.trim();
              if (newTitle.isNotEmpty) {
                await http.put(Uri.parse('http://127.0.0.1:8000/chats/$sessionId'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'title': newTitle}));
                setState(() { _currentChatTitle = newTitle; });
                await _fetchChats();
              }
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _deleteChat(String sessionId) async {
    await http.delete(Uri.parse('http://127.0.0.1:8000/chats/$sessionId'));
    await _fetchChats();
    if (_chats.isNotEmpty) { await _switchChat(_chats[0]['session_id'], _chats[0]['title']); } 
    else { await _createNewChat(); }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) { _scrollController.animateTo(_scrollController.position.maxScrollExtent, duration: const Duration(milliseconds: 300), curve: Curves.easeOut); }
    });
  }

  Future<void> _launchURL(String urlString) async {
    final Uri url = Uri.parse(urlString);
    if (!await launchUrl(url)) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_lang("Ne mogu otvoriti link.", "Cannot open link.")))); }
  }

  Future<void> _loadSavedModels() async {
    final prefs = await SharedPreferences.getInstance();
    String? savedData = prefs.getString('saved_ai_models');
    if (savedData != null) {
      List<dynamic> decodedList = jsonDecode(savedData);
      setState(() {
        _aiModels.clear();
        for (var item in decodedList) {
          var model = Map<String, dynamic>.from(item);
          if (!model.containsKey('max_tokens') || model['max_tokens'] == null) { model['max_tokens'] = 8000; }
          _aiModels.add(model);
        }
      });
      _saveModelsToStorage();
    }
  }

  Future<void> _saveModelsToStorage() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_ai_models', jsonEncode(_aiModels));
  }

  String _formatModelString(String provider, String userInputModel) {
    if (userInputModel.isEmpty) { return provider == 'Google Gemini' ? 'gemini/gemini-1.5-pro-latest' : 'openai/gpt-3.5-turbo'; }
    switch (provider) {
      case 'Google Gemini': return 'gemini/$userInputModel';
      case 'OpenAI': return 'openai/$userInputModel';
      case 'Anthropic': return 'anthropic/$userInputModel';
      case 'Groq': return 'groq/$userInputModel';
      case 'Lokalni (Ollama)': return 'ollama/$userInputModel';
      case 'OpenRouter': return 'openrouter/$userInputModel';
      default: return userInputModel;
    }
  }

  Future<void> _clearCurrentChatMemory() async {
    await _deleteChat(_currentSessionId);
    setState(() { _messages.clear(); _showContinueDebateButton = false; });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_lang("Trenutni razgovor je očišćen!", "Current chat memory cleared!"))));
  }

  Future<void> _fetchAvailableModels() async {
    String apiKey = _apiKeyController.text.trim();
    if (apiKey.isEmpty) return;
    showDialog(context: context, barrierDismissible: false, builder: (context) => const Center(child: CircularProgressIndicator(color: Colors.cyanAccent)));

    try {
      http.Response response;
      if (_selectedProvider == 'Google Gemini') { response = await http.get(Uri.parse('https://generativelanguage.googleapis.com/v1beta/models?key=$apiKey')); } 
      else { response = await http.get(Uri.parse(_selectedProvider == 'Groq' ? 'https://api.groq.com/openai/v1/models' : 'https://api.openai.com/v1/models'), headers: {"Authorization": "Bearer $apiKey"}); }
      Navigator.pop(context);
      if (response.statusCode == 200) {
        var data = jsonDecode(response.body); List<dynamic> modelsToDisplay = [];
        if (_selectedProvider == 'Google Gemini') {
          List<dynamic> geminiModels = data['models'] ?? [];
          for (var m in geminiModels) {
            String cleanName = m['name'].toString().replaceAll('models/', '');
            List<dynamic> methods = m['supportedGenerationMethods'] ?? [];
            if (methods.contains('generateContent') && cleanName.startsWith('gemini') && !cleanName.contains('1.0') && !cleanName.contains('1.5') && !cleanName.contains('2.5') && !cleanName.contains('vision')) { modelsToDisplay.add({'id': cleanName}); }
          }
        } else { modelsToDisplay = data['data'] ?? []; }
        _showModelsDialog(modelsToDisplay);
      }
    } catch (e) { Navigator.pop(context); }
  }

  void _showModelsDialog(List<dynamic> models) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          title: Text(_lang("Dostupni modeli", "Available Models")),
          content: SizedBox(width: double.maxFinite, height: 400, child: ListView.builder(itemCount: models.length, itemBuilder: (context, index) {
            String modelId = models[index]['id'];
            return Card(color: const Color(0xFF0F172A), child: ListTile(title: Text(modelId, style: const TextStyle(fontSize: 14)), trailing: IconButton(icon: const Icon(Icons.copy, color: Colors.cyanAccent), onPressed: () { Clipboard.setData(ClipboardData(text: modelId)); setState(() { _modelController.text = modelId; }); Navigator.pop(context); })));
          })),
          actions: [TextButton(child: Text(_lang("Zatvori", "Close")), onPressed: () => Navigator.pop(context))],
        );
      },
    );
  }

  Future<void> _sendMessage() async {
    if (_chatController.text.isEmpty && _base64Image == null) return;
    var activeModels = _aiModels.where((m) => m['is_active'] == true).toList();
    String userMessage = _chatController.text.isEmpty ? "[Poslana slika]" : _chatController.text;
    setState(() { _showContinueDebateButton = false; });

    if (activeModels.isEmpty) {
      if (userMessage.length > 50) { 
        setState(() { _messages.add({"role": "user", "content": _lang("Ti: [Slanje dokumenta u bazu ovog chata...]", "You: [Sending document to database...]")}); _chatController.clear(); });
        _scrollToBottom(); 
        try {
          final response = await http.post(Uri.parse('http://127.0.0.1:8000/memorize'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'session_id': _currentSessionId, 'text': userMessage}));
          if (response.statusCode == 200) { var data = jsonDecode(response.body); setState(() { _messages.add({"role": "system", "content": "Sistem:
✅ ${data['message']}"}); }); } 
          else { setState(() { _messages.add({"role": "system", "content": _lang("Greška: Nije uspjelo spremanje.", "Error: Failed to save.")}); }); }
        } catch (e) {}
        _scrollToBottom(); return; 
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_lang("Tekst je prekratak za bazu. Upali barem jedan model!", "Text too short for database. Turn on at least one model!")))); return;
      }
    }

    setState(() { _messages.add({"role": "user", "content": _lang("Ti: ", "You: ") + userMessage}); _chatController.clear(); }); _scrollToBottom(); 
    bool isFirst = true;

    for (var currentModel in activeModels) {
      setState(() { _messages.add({"role": "assistant", "content": "Agent (${currentModel['provider']}): ${_lang("Razmišljam...", "Thinking...")}"}); }); _scrollToBottom(); 
      int messageIndex = _messages.length - 1;
      try {
        final response = await http.post(Uri.parse('http://127.0.0.1:8000/chat'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'session_id': _currentSessionId, 'message': userMessage, 'provider': currentModel['provider'], 'api_key': currentModel['raw_key'], 'model': currentModel['full_model_string'], 'save_user_prompt': isFirst, 'image_base64': _base64Image, 'max_tokens': currentModel['max_tokens'], 'is_debate': false }));
        if (response.statusCode == 200) { var data = jsonDecode(response.body); setState(() { _messages[messageIndex] = {"role": "assistant", "content": "Agent (${currentModel['provider']}):
${data['reply']}"}; }); } 
        else { setState(() { _messages[messageIndex] = {"role": "assistant", "content": _lang("Greška", "Error") + " (${currentModel['provider']})"}; }); }
      } catch (e) { setState(() { _messages[messageIndex] = {"role": "assistant", "content": _lang("Greška u konekciji.", "Connection error.")}; }); }
      _scrollToBottom(); isFirst = false;
    }
    setState(() { _base64Image = null; }); await _fetchChats();
  }

  Future<void> _runDebate(String initialMessage, {bool isContinuing = false}) async {
    if (_base64Image != null) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_lang("Slike nisu podržane u debati.", "Images not supported in debate.")))); return; }
    var activeModels = _aiModels.where((m) => m['is_active'] == true).toList();
    if (activeModels.length < 2) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_lang("Za debatu trebaju barem 2 modela!", "Debate requires at least 2 models!")))); return; }

    setState(() { _isDebateRunning = true; _showContinueDebateButton = false; if (!isContinuing && initialMessage.isNotEmpty) { _messages.add({"role": "user", "content": "${_lang("Ti", "You")}: [DEBATA] $initialMessage"}); } });
    _scrollToBottom();
    int roundsLimit = 3; bool firstRequest = !isContinuing;

    for (int krug = 1; krug <= roundsLimit; krug++) {
      if (!_isDebateRunning) break;
      for (var currentModel in activeModels) {
        if (!_isDebateRunning) break;
        setState(() { _messages.add({"role": "assistant", "content": "Porota (${currentModel['provider']}): ${_lang("Razmišlja (Krug", "Thinking (Round")} $krug)..."}); }); _scrollToBottom(); int messageIndex = _messages.length - 1;

        try {
          final response = await http.post(Uri.parse('http://127.0.0.1:8000/chat'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'session_id': _currentSessionId, 'message': firstRequest ? initialMessage : _lang("Nastavite sa debatom i glasanjem.", "Continue debate and voting."), 'provider': currentModel['provider'], 'api_key': currentModel['raw_key'], 'model': currentModel['full_model_string'], 'save_user_prompt': firstRequest, 'image_base64': null, 'max_tokens': currentModel['max_tokens'], 'is_debate': true }));
          firstRequest = false;
          if (response.statusCode == 200) {
            var data = jsonDecode(response.body); String aiReply = data['reply'];
            setState(() { _messages[messageIndex] = {"role": "assistant", "content": "Porota (${currentModel['provider']}):
$aiReply"}; }); _scrollToBottom();
            if (aiReply.contains("[KRAJ_DEBATE]") || aiReply.contains("[END_DEBATE]")) {
              setState(() { _isDebateRunning = false; }); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_lang("Porota je donijela odluku!", "Jury reached a decision!")))); await _fetchChats(); return; 
            }
          }
        } catch (e) {}
      }
    }
    if (_isDebateRunning) { setState(() { _isDebateRunning = false; _showContinueDebateButton = true; }); _scrollToBottom(); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_lang("Debata pauzirana.", "Debate paused.")))); }
    await _fetchChats();
  }

  void _addAiModel() {
    if (_apiKeyController.text.isNotEmpty || _selectedProvider == 'Lokalni (Ollama)') {
      setState(() {
        String rawKey = _apiKeyController.text; String hiddenKey = rawKey.isEmpty ? 'Lokalni' : '***${rawKey.substring(rawKey.length > 4 ? rawKey.length - 4 : 0)}'; String userInputModel = _modelController.text.trim(); int limitTokena = int.tryParse(_tokenLimitController.text) ?? 8000;
        _aiModels.add({'provider': _selectedProvider, 'key': hiddenKey, 'raw_key': rawKey, 'display_model': userInputModel.isEmpty ? 'Default' : userInputModel, 'full_model_string': _formatModelString(_selectedProvider, userInputModel), 'max_tokens': limitTokena, 'is_active': true, });
        _apiKeyController.clear(); _modelController.clear(); _tokenLimitController.clear(); _isSettingsExpanded = false;
      });
      _saveModelsToStorage();
    }
  }

  void _editTokenLimit(int index) {
    TextEditingController editTokenController = TextEditingController(text: _aiModels[index]['max_tokens'].toString());
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: Text(_lang("Uredi limite", "Edit Limits")),
        content: TextField(controller: editTokenController, keyboardType: TextInputType.number, decoration: InputDecoration(border: OutlineInputBorder(), hintText: _lang("Broj tokena", "Token amount"))),
        actions: [
          TextButton(child: Text(_lang("Odustani", "Cancel")), onPressed: () => Navigator.pop(context)),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.cyanAccent),
            child: Text(_lang("Sačuvaj", "Save"), style: const TextStyle(color: Colors.black)),
            onPressed: () { setState(() { _aiModels[index]['max_tokens'] = int.tryParse(editTokenController.text.trim()) ?? 8000; }); _saveModelsToStorage(); Navigator.pop(context); },
          ),
        ],
      ),
    );
  }

  Widget _buildApiLink(String title, String url, IconData icon) {
    return ListTile(
      leading: Icon(icon, color: Colors.cyanAccent, size: 20),
      title: Text(title, style: const TextStyle(fontSize: 13)),
      trailing: const Icon(Icons.open_in_new, size: 16, color: Colors.grey),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 0.0),
      dense: true,
      onTap: () => _launchURL(url),
    );
  }

  void _showGuideDialog() {
    String guideTextBA = """
# KORISNIČKO UPUTSTVO

**1. POČETNO PODEŠAVANJE (Dodavanje AI Modela)**
- Kliknite na "Dodaj AI Model" u meniju desno.
- Odaberite provajdera i unesite API ključ (Ollama ne traži ključ).
- Unesite tačan naziv modela i postavite limit tokena.
- *SAVJET: Ako ne znate tačan naziv modela za vaš API, potražite ga u zvaničnoj dokumentaciji provajdera.*

**2. ORGANIZACIJA PROJEKATA**
- Svaki chat je potpuno nezavisan. Baza znanja koju napunite u jednom chatu neće se miješati sa drugim.
- Preimenujte razgovore klikom na ikonu olovke kako biste lakše radili na više projekata.

**3. OBIČNI CHAT (Paralelno procesiranje)**
- Upalite željene modele (ikona mora svijetliti zeleno).
- Unesite zadatak i kliknite plavo dugme. Svi modeli će odgovoriti istovremeno.

**4. PUNJENJE BAZE ZNANJA**
- **UGASITE** sve modele.
- Zalijepite dugačak tekst ili kod (preko 50 karaktera) i kliknite plavo dugme za slanje.
- Sistem će tekst pohraniti u bazu. Zatim upalite modele, i oni će automatski koristiti taj tekst za odgovore.

**5. AI POROTA (Autonomna Debata)**
- Upalite barem 2 različita modela.
- Unesite kompleksan problem i kliknite NARANDŽASTO dugme (čekić).
- Modeli će raspravljati između sebe. Kada postignu dogovor ispisaće `[SLAŽEM_SE]` i servirati `[KONAČNO_RJEŠENJE]`.
""";

    String guideTextEN = """
# USER GUIDE

**1. INITIAL SETUP (Adding AI Models)**
- Click "Add AI Model" in the right menu.
- Select a provider and enter the API key (Ollama does not require one).
- Enter the exact model name and set the token limit.
- *TIP: If you are unsure of the exact model name for your API, check the provider's official documentation.*

**2. PROJECT ORGANIZATION**
- Every chat is completely independent. Knowledge bases do not mix between chats.
- Rename conversations using the pencil icon to organize your projects easily.

**3. STANDARD CHAT (Parallel Processing)**
- Turn on desired models (the power icon must be green).
- Enter a prompt and click the blue button. All active models will reply simultaneously.

**4. BUILDING THE KNOWLEDGE BASE**
- **Turn OFF** all models.
- Paste a long text or code (over 50 characters) and click the blue send button.
- The system will save it to the database. Turn the models back on, and they will use it as context.

**5. AI JURY (Autonomous Debate)**
- Turn on at least 2 different models.
- Enter a complex problem and click the ORANGE gavel button.
- Models will debate with each other. When they agree, they will output `[SLAŽEM_SE]` and serve the `[FINAL_SOLUTION]`.
""";

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: Row(
          children: [
            const Icon(Icons.menu_book, color: Colors.cyanAccent),
            const SizedBox(width: 10),
            Text(_lang("Uputstvo za korištenje", "User Guide"), style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: SingleChildScrollView(
            child: MarkdownBody(
              data: _lang(guideTextBA, guideTextEN), 
              styleSheet: MarkdownStyleSheet(
                p: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
                strong: const TextStyle(color: Colors.white),
                listBullet: const TextStyle(color: Colors.cyanAccent),
                code: const TextStyle(backgroundColor: Color(0xFF0B1121), color: Colors.cyanAccent),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context), 
            child: Text(_lang("Zatvori", "Close"), style: const TextStyle(color: Colors.cyanAccent))
          )
        ],
      )
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                // LIJEVI PANEL
                Expanded(
                  flex: 2,
                  child: Container(
                    color: const Color(0xFF0B1121),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 16.0, left: 16.0, right: 16.0, bottom: 8.0),
                          child: Row(
                            children: [
                              Image.asset('assets/favicon-master.png', height: 32, errorBuilder: (context, error, stackTrace) => const Icon(Icons.shield, color: Colors.cyanAccent)),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Text("SCANWEB AI", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.cyanAccent), overflow: TextOverflow.ellipsis),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: ElevatedButton.icon(
                            onPressed: _createNewChat,
                            icon: const Icon(Icons.add, size: 18),
                            label: Text(_lang("+ Novi Chat", "+ New Chat")),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.cyanAccent, foregroundColor: Colors.black, minimumSize: const Size(double.infinity, 40),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
                          child: Text(_lang("Teme / Razgovori", "Topics / Chats"), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey)),
                        ),
                        const Divider(height: 1, color: Colors.white12),
                        Expanded(
                          child: ListView.builder(
                            itemCount: _chats.length,
                            itemBuilder: (context, index) {
                              final chat = _chats[index];
                              bool isSelected = chat['session_id'] == _currentSessionId;
                              return Container(
                                color: isSelected ? const Color(0xFF1E293B) : Colors.transparent,
                                child: ListTile(
                                  leading: Icon(Icons.chat_bubble_outline, size: 18, color: isSelected ? Colors.cyanAccent : Colors.grey),
                                  title: Text(chat['title'], style: TextStyle(fontSize: 13, color: isSelected ? Colors.white : Colors.grey), maxLines: 1, overflow: TextOverflow.ellipsis),
                                  onTap: () => _switchChat(chat['session_id'], chat['title']),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(icon: const Icon(Icons.edit, size: 14, color: Colors.grey), onPressed: () => _renameChat(chat['session_id'])),
                                      IconButton(icon: const Icon(Icons.delete_outline, size: 14, color: Colors.redAccent), onPressed: () => _deleteChat(chat['session_id'])),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const Divider(height: 1, color: Colors.white12),
                        
                        Padding(
                          padding: const EdgeInsets.only(top: 16.0, left: 16.0, right: 8.0, bottom: 8.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(_lang("KORISNI LINKOVI", "USEFUL LINKS"), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.grey)),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text("🇧🇦", style: TextStyle(fontSize: 16, color: !_isEnglish ? Colors.white : Colors.white24)),
                                  Switch(
                                    value: _isEnglish, activeColor: Colors.cyanAccent, inactiveThumbColor: Colors.cyanAccent, inactiveTrackColor: Colors.grey.withOpacity(0.3),
                                    onChanged: (val) { setState(() { _isEnglish = val; }); }
                                  ),
                                  Text("🇬🇧", style: TextStyle(fontSize: 16, color: _isEnglish ? Colors.white : Colors.white24)),
                                ],
                              )
                            ],
                          ),
                        ),
                        _buildApiLink("Google Gemini API", "https://aistudio.google.com/app/apikey", Icons.auto_awesome),
                        _buildApiLink("Groq Cloud API", "https://console.groq.com/keys", Icons.bolt),
                        _buildApiLink("OpenRouter API", "https://openrouter.ai/keys", Icons.router),
                        const SizedBox(height: 10),

                        FadeTransition(
                          opacity: _blinkAnimation,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                            child: ElevatedButton.icon(
                              onPressed: _showGuideDialog,
                              icon: const Icon(Icons.menu_book, color: Colors.black),
                              label: Text(_lang("UPUTSTVO ZA RAD", "USER GUIDE"), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.cyanAccent,
                                minimumSize: const Size(double.infinity, 36),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
                
                // SREDNJI PANEL (CHAT SA MARKDOWN PODRŠKOM)
                Expanded(
                  flex: 6,
                  child: Container(
                    color: const Color(0xFF0F172A),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text("${_lang("Tema:", "Topic:")} $_currentChatTitle", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white)),
                              IconButton(
                                icon: const Icon(Icons.delete_sweep, color: Colors.redAccent, size: 28),
                                tooltip: _lang("Obriši chat", "Clear chat"),
                                onPressed: _clearCurrentChatMemory,
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1, color: Colors.white12),
                        Expanded(
                          child: ListView.builder(
                            controller: _scrollController, 
                            padding: const EdgeInsets.all(16.0),
                            itemCount: _messages.length,
                            itemBuilder: (context, index) {
                              String content = _messages[index]['content'] ?? '';
                              bool isUser = content.startsWith("Ti:") || content.startsWith("You:");
                              
                              return Align(
                                alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                                child: Container(
                                  margin: const EdgeInsets.symmetric(vertical: 6.0),
                                  padding: const EdgeInsets.all(14.0),
                                  decoration: BoxDecoration(
                                    color: isUser ? const Color(0xFF1E293B) : const Color(0xFF162032),
                                    border: Border.all(color: isUser ? Colors.cyanAccent.withOpacity(0.3) : Colors.transparent),
                                    borderRadius: BorderRadius.circular(12.0),
                                  ),
                                  child: Builder(
                                    builder: (context) {
                                      // PARSIRANJE IMENA AGENTA
                                      String namePart = "";
                                      String textPart = content;

                                      if (!isUser) {
                                        int splitIndex = content.indexOf("):");
                                        if (splitIndex != -1 && (content.startsWith("Agent") || content.startsWith("Porota") || content.startsWith("Jury") || content.startsWith("Greška") || content.startsWith("Error") || content.startsWith("Sistem"))) {
                                          namePart = content.substring(0, splitIndex + 2);
                                          textPart = content.substring(splitIndex + 2).trim();
                                        }
                                      }

                                      return Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          // PRIKAZ PLAVOG IMENA
                                          if (namePart.isNotEmpty)
                                            Padding(
                                              padding: const EdgeInsets.only(bottom: 8.0),
                                              child: Text(namePart, style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 15)),
                                            ),
                                          
                                          // PRIKAZ MARKDOWNA ZA AI
                                          if (!isUser)
                                            Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                MarkdownBody(
                                                  data: textPart,
                                                  selectable: false, // Ostavljamo ugaseno da aplikacija ne bi blokirala
                                                  builders: {
                                                    'pre': CodeBlockBuilder(context), 
                                                  },
                                                  styleSheet: MarkdownStyleSheet(
                                                    p: const TextStyle(color: Colors.white70, height: 1.5, fontSize: 14),
                                                    code: TextStyle(backgroundColor: Colors.white.withOpacity(0.1), color: Colors.white, fontFamily: 'monospace'),
                                                    h1: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                                    h2: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                                    h3: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                                    listBullet: const TextStyle(color: Colors.cyanAccent),
                                                    tableBorder: TableBorder.all(color: Colors.white24, width: 1),
                                                    tableCellsPadding: const EdgeInsets.all(10),
                                                    tableHead: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                                    tableBody: const TextStyle(color: Colors.white70),
                                                    blockquoteDecoration: const BoxDecoration(
                                                      color: Color(0xFF162032),
                                                      border: Border(left: BorderSide(color: Colors.cyanAccent, width: 4)),
                                                    ),
                                                    blockquote: const TextStyle(color: Colors.white70, fontStyle: FontStyle.italic),
                                                  ),
                                                ),
                                                // NOVO: DUGME ZA KOPIRANJE CIJELE PORUKE
                                                Align(
                                                  alignment: Alignment.centerRight,
                                                  child: IconButton(
                                                    icon: const Icon(Icons.content_copy, size: 16, color: Colors.grey),
                                                    tooltip: _lang("Kopiraj poruku", "Copy message"),
                                                    onPressed: () {
                                                      Clipboard.setData(ClipboardData(text: textPart));
                                                      ScaffoldMessenger.of(context).showSnackBar(
                                                        SnackBar(content: Text(_lang("Cijela poruka kopirana!", "Entire message copied!")), duration: const Duration(seconds: 1))
                                                      );
                                                    },
                                                  ),
                                                ),
                                              ],
                                            )
                                          // PRIKAZ OBIČNOG TEKSTA ZA KORISNIKA
                                          else
                                            SelectableText(content, style: const TextStyle(color: Colors.white70, height: 1.5, fontSize: 14)),
                                        ],
                                      );
                                    }
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            children: [
                              if (_showContinueDebateButton)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8.0),
                                  child: ElevatedButton.icon(
                                    icon: const Icon(Icons.play_arrow),
                                    label: Text(_lang("Debata pauzirana. Klikni za nastavak!", "Debate paused. Click to continue!")),
                                    style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white),
                                    onPressed: () { _runDebate("", isContinuing: true); },
                                  ),
                                ),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  IconButton(
                                    icon: Icon(Icons.image, color: _base64Image != null ? Colors.cyanAccent : Colors.grey),
                                    onPressed: _isDebateRunning ? null : () async {
                                      FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.image);
                                      if (result != null) {
                                        File file = File(result.files.single.path!);
                                        List<int> imageBytes = await file.readAsBytes();
                                        setState(() { _base64Image = base64Encode(imageBytes); });
                                      }
                                    },
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    // NOVO: Focus widget osluškuje tvoju tipkovnicu
                                    child: Focus(
                                      onKeyEvent: (FocusNode node, KeyEvent event) {
                                        // Provjeravamo je li pritisnuta tipka Enter
                                        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.enter) {
                                          // Ako korisnik drži Shift, dopuštamo prelazak u novi red
                                          if (HardwareKeyboard.instance.isShiftPressed) {
                                            return KeyEventResult.ignored; 
                                          } else {
                                            // Ako ne drži Shift, šaljemo poruku i sprječavamo dodavanje praznog reda
                                            if (!_isDebateRunning && _chatController.text.trim().isNotEmpty) {
                                              _sendMessage();
                                            }
                                            return KeyEventResult.handled;
                                          }
                                        }
                                        return KeyEventResult.ignored;
                                      },
                                      child: TextField(
                                        controller: _chatController,
                                        enabled: !_isDebateRunning,
                                        minLines: 1, 
                                        maxLines: 5, // Ovo garantira da tekst nikada ne bježi u desno!
                                        keyboardType: TextInputType.multiline,
                                        style: const TextStyle(color: Colors.white),
                                        decoration: InputDecoration(
                                          hintText: _lang("Unesi komandu ili dokument...", "Enter command or document..."),
                                          hintStyle: const TextStyle(color: Colors.white30),
                                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                                          filled: true,
                                          fillColor: const Color(0xFF1E293B),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  FloatingActionButton(
                                    heroTag: "btnDebate",
                                    onPressed: _isDebateRunning ? null : () {
                                      if (_chatController.text.isNotEmpty) { _runDebate(_chatController.text); _chatController.clear(); }
                                    },
                                    backgroundColor: _isDebateRunning ? Colors.grey : Colors.orangeAccent,
                                    tooltip: _lang("Pokreni AI Debatu", "Start AI Debate"),
                                    child: _isDebateRunning ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Icon(Icons.gavel, color: Colors.white),
                                  ),
                                  const SizedBox(width: 8),
                                  FloatingActionButton(
                                    heroTag: "btnNormal",
                                    onPressed: _isDebateRunning ? null : _sendMessage,
                                    backgroundColor: _isDebateRunning ? Colors.grey : Colors.cyanAccent,
                                    tooltip: _lang("Pošalji (Obični chat)", "Send (Normal chat)"),
                                    child: const Icon(Icons.send, color: Colors.black),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                
                // DESNI PANEL (POSTAVKE I MODELI)
                Expanded(
                  flex: 2,
                  child: Container(
                    color: const Color(0xFF0B1121),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InkWell(
                          onTap: () { setState(() { _isSettingsExpanded = !_isSettingsExpanded; }); },
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(_lang("Dodaj AI Model", "Add AI Model"), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.cyanAccent)),
                                Icon(_isSettingsExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, color: Colors.cyanAccent),
                              ],
                            ),
                          ),
                        ),
                        const Divider(height: 1, color: Colors.white12),
                        
                        if (_isSettingsExpanded)
                          Padding(
                            padding: const EdgeInsets.all(12.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                DropdownButton<String>(
                                  value: _selectedProvider, isExpanded: true, dropdownColor: const Color(0xFF1E293B),
                                  items: _providers.map((String value) { return DropdownMenuItem<String>(value: value, child: Text(value, style: const TextStyle(color: Colors.white))); }).toList(),
                                  onChanged: (newValue) { setState(() { _selectedProvider = newValue!; }); },
                                ),
                                const SizedBox(height: 8),
                                TextField(controller: _apiKeyController, decoration: InputDecoration(hintText: _lang("API Ključ", "API Key"), border: const OutlineInputBorder(), isDense: true), obscureText: true),
                                const SizedBox(height: 8),
                                OutlinedButton.icon(
                                  onPressed: _fetchAvailableModels, icon: const Icon(Icons.search, size: 18), label: Text(_lang("Učitaj modele", "Load Models")),
                                  style: OutlinedButton.styleFrom(foregroundColor: Colors.cyanAccent, side: const BorderSide(color: Colors.cyanAccent)),
                                ),
                                const SizedBox(height: 12),
                                TextField(controller: _modelController, decoration: InputDecoration(hintText: _lang("Ime modela", "Model name"), border: const OutlineInputBorder(), isDense: true)),
                                const SizedBox(height: 12),
                                TextField(controller: _tokenLimitController, keyboardType: TextInputType.number, decoration: InputDecoration(hintText: _lang("Limit tokena", "Token limit"), border: const OutlineInputBorder(), isDense: true)),
                                const SizedBox(height: 12),
                                ElevatedButton.icon(
                                  onPressed: _addAiModel, icon: const Icon(Icons.add), label: Text(_lang("Dodaj", "Add")),
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.cyanAccent, foregroundColor: Colors.black),
                                ),
                              ],
                            ),
                          ),
                        if (_isSettingsExpanded) const Divider(height: 1, color: Colors.white12),
                        
                        Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: Text(_lang("Aktivni Modeli", "Active Models"), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
                        ),
                        
                        Expanded(
                          child: Scrollbar(
                            controller: _modelsScrollController,
                            thumbVisibility: true, thickness: 6.0, radius: const Radius.circular(10),
                            child: ListView.builder(
                              controller: _modelsScrollController,
                              padding: const EdgeInsets.only(right: 8.0, bottom: 8.0),
                              itemCount: _aiModels.length,
                              itemBuilder: (context, index) {
                                final model = _aiModels[index];
                                return Card(
                                  color: model['is_active'] ? const Color(0xFF1E293B) : const Color(0xFF0F172A),
                                  margin: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
                                  shape: RoundedRectangleBorder(
                                    side: BorderSide(color: model['is_active'] ? Colors.cyanAccent.withOpacity(0.5) : Colors.transparent, width: 1),
                                    borderRadius: BorderRadius.circular(8.0),
                                  ),
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 2.0), dense: true,
                                    title: Text(model['provider']!, style: TextStyle(fontWeight: model['is_active'] ? FontWeight.bold : FontWeight.normal, fontSize: 13, color: Colors.white), maxLines: 1, overflow: TextOverflow.ellipsis),
                                    subtitle: Padding(
                                      padding: const EdgeInsets.only(top: 2.0),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(model['display_model'], style: const TextStyle(fontSize: 11, color: Colors.grey), maxLines: 1, overflow: TextOverflow.ellipsis),
                                          const SizedBox(height: 2),
                                          Text("Limit: ${model['max_tokens']} tokena", style: const TextStyle(fontSize: 11, color: Colors.cyanAccent), maxLines: 1, overflow: TextOverflow.ellipsis),
                                        ],
                                      ),
                                    ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(icon: const Icon(Icons.edit, color: Colors.grey, size: 16), constraints: const BoxConstraints(), onPressed: () { _editTokenLimit(index); }),
                                        const SizedBox(width: 8),
                                        IconButton(icon: Icon(Icons.power_settings_new, color: model['is_active'] ? Colors.greenAccent : Colors.redAccent, size: 20), constraints: const BoxConstraints(), onPressed: () { setState(() { _aiModels[index]['is_active'] = !_aiModels[index]['is_active']; }); _saveModelsToStorage(); }),
                                        const SizedBox(width: 8),
                                        IconButton(icon: const Icon(Icons.delete, color: Colors.grey, size: 18), constraints: const BoxConstraints(), onPressed: () { setState(() { _aiModels.removeAt(index); }); _saveModelsToStorage(); }),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          // SVJETLEĆI FOOTER
          Container(
            height: 30, width: double.infinity, color: Colors.black, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 16.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text("Powered by BOSNIA.BOY ", style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                InkWell(
                  onTap: () => _launchURL("https://scanweb.net/"),
                  child: const Text(
                    "scanweb.net",
                    style: TextStyle(
                      color: Colors.cyanAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                      shadows: [Shadow(color: Colors.cyanAccent, blurRadius: 10)], 
                    ),
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

// =========================================================================
// NOVO: KLASA ZA CRTANJE CODE BLOKOVA SA "COPY" DUGMETOM
// =========================================================================
class CodeBlockBuilder extends MarkdownElementBuilder {
  final BuildContext context;
  CodeBlockBuilder(this.context);

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12.0),
      decoration: BoxDecoration(
        color: const Color(0xFF070B14), // Još tamnija pozadina za sam kod
        borderRadius: BorderRadius.circular(8.0),
        border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ZAGLAVLJE SA COPY DUGMETOM
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
            decoration: const BoxDecoration(
              color: Color(0xFF162032),
              borderRadius: BorderRadius.vertical(top: Radius.circular(8.0)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Code", style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: element.textContent));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Kod kopiran! / Code copied!"), duration: Duration(seconds: 1)));
                  },
                  child: const Row(
                    children: [
                      Icon(Icons.copy, size: 14, color: Colors.cyanAccent),
                      SizedBox(width: 4),
                      Text("Copy", style: TextStyle(color: Colors.cyanAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // PRAVI KOD UNUTAR BLOKA
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: SelectableText(
              element.textContent,
              style: const TextStyle(fontFamily: 'monospace', color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
