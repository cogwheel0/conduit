import 'dart:math';

class ReviewerModeService {
  static final Random _random = Random();

  // Categories of canned responses
  static const Map<String, List<String>> _cannedResponses = {
    'greeting': [
      'Hello! I\'m here to help you explore Conduit\'s features. What would you like to know?',
      'Hi there! Welcome to Conduit. How can I assist you today?',
      'Greetings! I\'m ready to help you test out Conduit\'s chat capabilities.',
    ],
    'code': [
      'Here\'s a simple example of what I can help with:\n\n```python\ndef greet(name):\n    return f"Hello, {name}!"\n\nprint(greet("Conduit User"))\n```\n\nI can assist with various programming languages and tasks.',
      'I can help you write and review code. For example:\n\n```javascript\nconst calculateSum = (numbers) => {\n  return numbers.reduce((acc, num) => acc + num, 0);\n};\n\nconsole.log(calculateSum([1, 2, 3, 4, 5])); // Output: 15\n```',
      'Let me show you a code snippet:\n\n```typescript\ninterface User {\n  id: string;\n  name: string;\n  email: string;\n}\n\nclass UserService {\n  async getUser(id: string): Promise<User> {\n    // Implementation here\n    return { id, name: "Demo User", email: "demo@conduit.app" };\n  }\n}\n```',
    ],
    'features': [
      'Conduit offers several key features:\n\n• **Real-time streaming** - See responses as they\'re generated\n• **File attachments** - Share images and documents\n• **Voice input** - Speak your queries\n• **Multiple models** - Choose from various AI models\n• **Conversation history** - Access your past chats\n\nWhat feature would you like to explore?',
      'Here are some things you can do with Conduit:\n\n1. **Chat with AI** - Have natural conversations\n2. **Share files** - Upload images and documents for analysis\n3. **Use voice** - Tap the microphone for hands-free input\n4. **Switch models** - Try different AI models for varied responses\n5. **Search history** - Find past conversations easily\n\nWhich capability interests you most?',
    ],
    'attachments': [
      'I see you\'ve shared a file! In Conduit, I can analyze:\n\n• **Images** - Describe, analyze, or answer questions about pictures\n• **Documents** - Review and summarize text files\n• **Code files** - Help debug or explain code\n\nThe file "{filename}" has been received. What would you like me to do with it?',
      'Thank you for sharing "{filename}"! I can help you:\n\n• Extract information\n• Analyze content\n• Answer questions about it\n• Provide summaries\n\nWhat specific aspect would you like me to focus on?',
    ],
    'voice': [
      'Great! You\'re using voice input. This feature allows for hands-free interaction with Conduit. I heard: "{transcript}"\n\nVoice input is perfect for:\n• Quick queries\n• Accessibility\n• Multitasking\n\nHow else can I help you?',
      'I received your voice message: "{transcript}"\n\nVoice input makes conversations more natural and convenient. Feel free to continue speaking or typing - whatever works best for you!',
    ],
    'general': [
      'That\'s an interesting question! Let me think about "{query}".\n\nIn Conduit, you can explore various topics and get detailed responses. The app is designed to be your AI companion for learning, creating, and problem-solving.\n\n(Demo Mode: These are sample responses for app review)',
      'Regarding "{query}", here\'s what I can share:\n\nConduit provides a seamless chat experience with advanced AI capabilities. Whether you\'re looking for information, creative assistance, or technical help, I\'m here to support you.\n\nNote: This is a demo response - actual usage requires your own AI server.',
      'I understand you\'re asking about "{query}". \n\nThis demo shows how Conduit handles conversations. In real use, you\'d connect to your own AI server for actual AI responses.\n\nTry uploading an image or using voice input to see more features!',
    ],
    'error': [
      'I noticed there might be an issue. In a production environment, Conduit handles errors gracefully and provides helpful feedback. This demo mode simulates that experience.\n\nPlease try your request again, or let me know how I can help differently!',
      'It seems something unexpected happened. Conduit is designed to recover smoothly from errors and continue providing assistance.\n\nWould you like to try a different query or explore another feature?',
    ],
  };

  static String generateResponse({
    required String userMessage,
    String? filename,
    bool isVoiceInput = false,
  }) {
    final lowerMessage = userMessage.toLowerCase();

    // Determine response category
    String category = 'general';

    if (lowerMessage.contains('hello') ||
        lowerMessage.contains('hi') ||
        lowerMessage.contains('hey') ||
        lowerMessage.contains('greet')) {
      category = 'greeting';
    } else if (lowerMessage.contains('code') ||
        lowerMessage.contains('program') ||
        lowerMessage.contains('function') ||
        lowerMessage.contains('debug')) {
      category = 'code';
    } else if (lowerMessage.contains('feature') ||
        lowerMessage.contains('capability') ||
        lowerMessage.contains('what can') ||
        lowerMessage.contains('help')) {
      category = 'features';
    } else if (filename != null) {
      category = 'attachments';
    } else if (isVoiceInput) {
      category = 'voice';
    }

    // Get responses for category
    final responses =
        _cannedResponses[category] ?? _cannedResponses['general']!;
    final response = responses[_random.nextInt(responses.length)];

    // Replace placeholders
    return response
        .replaceAll('{query}', userMessage)
        .replaceAll('{filename}', filename ?? 'file')
        .replaceAll('{transcript}', userMessage);
  }

  static String generateStreamingResponse({
    required String userMessage,
    String? filename,
    bool isVoiceInput = false,
  }) {
    // For streaming, we'll return the same response but the UI will handle chunking
    return generateResponse(
      userMessage: userMessage,
      filename: filename,
      isVoiceInput: isVoiceInput,
    );
  }
}
