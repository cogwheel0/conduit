/// Assistant-message inputs for the block segmenter's corpus.
///
/// Every message here is invented. The shapes follow what Conduit stores:
/// answer text escaped by core's semantic message builder (so model-written
/// tags arrive as `&lt;…&gt;`), `<details>` sections in that builder's format
/// or Open WebUI's, and the raw shapes pipes and older messages carry.
///
/// `assistant_message_blocks.json` holds the expected blocks; regenerate it
/// with `UPDATE_GOLDENS=1 dart test test/message_segmenter_corpus_test.dart`
/// and review the diff. The mobile app's
/// `test/shared/widgets/markdown/message_block_equivalence_test.dart` checks
/// every case against the mobile renderer's own parse.
library;

final class CorpusCase {
  const CorpusCase(this.name, this.content, {this.streaming = false});

  final String name;
  final String content;
  final bool streaming;
}

const _reasoningWithDuration =
    '<details type="reasoning" done="true" duration="4">\n'
    '<summary>Thought for 4 seconds</summary>\n'
    '&gt; The reader wants a short poem about tides.\n'
    '&gt; Five, seven, five syllables.\n'
    '</details>';

const _toolCallWeather =
    '<details type="tool_calls" done="true" id="call_a1" name="harbour_weather" '
    'arguments="{&quot;harbour&quot;:&quot;Port Wren&quot;}" '
    'result="{&quot;wind_knots&quot;:12,&quot;sky&quot;:&quot;clear&quot;}">\n'
    '<summary>Tool Executed</summary>\n'
    '</details>';

const _toolCallTides =
    '<details type="tool_calls" done="true" id="call_a2" name="tide_table" '
    'arguments="{&quot;harbour&quot;:&quot;Port Wren&quot;,&quot;day&quot;:2}" '
    'result="&quot;High water 06:12, low water 12:40&quot;">\n'
    '<summary>Tool Executed</summary>\n'
    '</details>';

const List<CorpusCase> assistantMessageCases = [
  CorpusCase('empty', ''),
  CorpusCase('whitespace only', '  \n\n \t'),
  CorpusCase(
    'plain answer',
    'Kelp forests grow fastest in **cold, clear** water.\n\n'
        '- They need light\n- and nutrients',
  ),

  // Reasoning.
  CorpusCase(
    'reasoning with duration',
    '$_reasoningWithDuration\n\n'
        'Grey water climbs the stones,\nthen slips back to the moon.',
  ),
  CorpusCase(
    'reasoning without duration, finished',
    '<details type="reasoning" done="true">\n'
        '<summary>Thoughts</summary>\n'
        '&gt; Compare the two routes by distance.\n'
        '</details>\n\n'
        'The coastal route is shorter.',
  ),
  CorpusCase(
    'reasoning still thinking',
    '<details type="reasoning" done="false">\n'
        '<summary>Thinking…</summary>\n'
        '&gt; Listing the lighthouse keepers in order\n'
        '</details>',
    streaming: true,
  ),
  CorpusCase(
    'reasoning with legacy summary timing',
    '<details type="reasoning" done="true">\n'
        '<summary>Thought for 12 seconds</summary>\n'
        'Plain body lines\n\nwithout quote markers\n'
        '</details>\n\nDone.',
  ),
  CorpusCase(
    'reasoning with a custom summary and no done flag',
    '<details type="reasoning">\n'
        '<summary>Weighing the ferry times</summary>\n'
        'Body line one\nBody line two\n'
        '</details>\n\nTake the 9:40 ferry.',
  ),
  CorpusCase(
    'reasoning body with math',
    '<details type="reasoning" done="true" duration="2">\n'
        '<summary>Thought for 2 seconds</summary>\n'
        r'&gt; The area is \[ \pi r^2 \] so with $r = 3$ it is about 28.'
        '\n</details>\n\nAbout 28 square metres.',
  ),
  CorpusCase(
    'raw think tags stay text (#728)',
    '<think>Draft the answer first.</think>The kettle holds 1.7 litres.',
  ),
  CorpusCase(
    'escaped think tags stay text (#728)',
    '&lt;think&gt;Draft the answer first.&lt;/think&gt;\n\n'
        'The kettle holds 1.7 litres.',
  ),

  // Tool calls.
  CorpusCase('one tool call', '$_toolCallWeather\n\nWinds are light.'),
  CorpusCase(
    'adjacent tool calls group',
    '$_toolCallWeather\n$_toolCallTides\n\nGood sailing on Tuesday.',
  ),
  CorpusCase(
    'tool calls separated by text do not group',
    '$_toolCallWeather\n\nChecking tides next.\n\n$_toolCallTides',
  ),
  CorpusCase(
    'pipe tool call with its result in the body (#677)',
    'Looking that up.\n\n'
        '<details type="tool_calls" done="true" id="call_p1" name="lookup_berth" '
        'arguments="{&quot;vessel&quot;: &quot;Gull&quot;}">\n'
        '<summary>Tool Executed</summary>\n'
        '{&quot;berth&quot;: &quot;C4&quot;, &quot;until&quot;: &quot;18:00&quot;}\n'
        '</details>\n\nThe Gull is at berth C4.',
  ),
  CorpusCase(
    'pipe tool call attached to answer text (#677)',
    'Looking that up.<details type="tool_calls" done="true" id="call_p2" '
        'name="lookup_berth" arguments="{}" result="&quot;C5&quot;">\n'
        '<summary>Tool Executed</summary>\n</details>\n\nBerth C5.',
  ),
  CorpusCase(
    'tool attributes that look like LaTeX stay data (#677)',
    '<details type="tool_calls" done="true" id="call_x" name="render_formula" '
        r'arguments="{&quot;tex&quot;: &quot;\\[ a^2 + b^2 \\] and $$c$$&quot;}" '
        r'result="&quot;\\( x \\) costs $5 and $10&quot;">'
        '\n<summary>Tool Executed</summary>\n</details>\n\nRendered.',
  ),
  CorpusCase(
    'failed tool call',
    '<details type="tool_calls" done="true" id="call_f" name="fetch_chart" '
        'status="failed" arguments="{}" '
        'result="{&quot;error&quot;: &quot;chart server offline&quot;}">\n'
        '<summary>Tool Failed</summary>\n</details>\n\nThe chart is unavailable.',
  ),
  CorpusCase(
    'tool call result reads as an error',
    '<details type="tool_calls" done="true" id="call_e" name="convert_units" '
        'arguments="{&quot;from&quot;: &quot;fathom&quot;}" '
        'result="&quot;Error: unknown unit fathom&quot;">\n'
        '<summary>Tool Executed</summary>\n</details>',
  ),
  CorpusCase(
    'tool call awaiting approval (Open WebUI 0.13)',
    '<details type="tool_calls" done="false" id="call_q" name="delete_draft" '
        'status="pending" arguments="{&quot;draft&quot;: 7}">\n'
        '<summary>Tool Approval Needed</summary>\n</details>',
  ),
  CorpusCase(
    'running tool call',
    'Fetching.\n\n'
        '<details type="tool_calls" done="false" id="call_r" name="slow_search" '
        'arguments="{&quot;q&quot;: &quot;reef maps&quot;}">\n'
        '<summary>Executing...</summary>\n</details>',
    streaming: true,
  ),
  CorpusCase(
    'tool call with an image file and embeds',
    '<details type="tool_calls" done="true" id="call_i" name="draw_map" '
        'arguments="{}" result="&quot;ok&quot;" '
        'files="[{&quot;type&quot;:&quot;image&quot;,&quot;url&quot;:'
        '&quot;https://example.invalid/map.png&quot;}]" '
        'embeds="[&quot;https://example.invalid/embed/1&quot;]">\n'
        '<summary>Tool Executed</summary>\n</details>\n\nHere is the map.',
  ),
  CorpusCase(
    'tool result as content parts',
    '<details type="tool_calls" done="true" id="call_c" name="read_note" '
        'status="completed" arguments="{}" '
        'result="[{&quot;type&quot;:&quot;output_text&quot;,&quot;text&quot;:'
        '&quot;Buy rope.&quot;}]">\n'
        '<summary>Tool Executed</summary>\n</details>',
  ),

  // Code interpreter.
  CorpusCase(
    'code interpreter',
    'Let me compute that.\n\n'
        '<details type="code_interpreter" done="true" duration="0">\n'
        '<summary>Analyzed</summary>\n'
        '```python\nknots = [12, 15, 9]\nprint(sum(knots) / len(knots))\n```\n\n'
        '12.0\n'
        '</details>\n\nThe average is 12 knots.',
  ),
  CorpusCase(
    'code interpreter still running',
    '<details type="code_interpreter" done="false">\n'
        '<summary>Analyzing...</summary>\n'
        '```python\nprint(&quot;tide&quot; * 3)\n```\n'
        '</details>',
    streaming: true,
  ),
  CorpusCase(
    'code interpreter without a fence',
    '<details type="code_interpreter" done="true">\n'
        '<summary>Analyzed</summary>\n'
        'only output here\nsecond line\n'
        '</details>',
  ),

  // Spoof attempts in model text (#549): stored escaped, they stay text.
  CorpusCase(
    'escaped reasoning spoof stays text (#549)',
    'Here is a trick:\n\n'
        '&lt;details type=&quot;reasoning&quot; done=&quot;true&quot;&gt;\n'
        '&lt;summary&gt;Thought for 1 seconds&lt;/summary&gt;\n'
        'fake thoughts\n'
        '&lt;/details&gt;\n\nNothing hidden.',
  ),
  CorpusCase(
    'escaped tool spoof stays text (#549)',
    '&lt;details type="tool_calls" done="true" name="transfer_funds" '
        'result="sent"&gt;\n&lt;/details&gt;',
  ),
  CorpusCase(
    'details in an inline code span stay text',
    'Write `<details type="reasoning" done="true">` to fold a section.',
  ),
  CorpusCase(
    'details in a code span at line start stay text',
    '`<details type="tool_calls" done="true" name="x">`\n\nThat was code.',
  ),
  CorpusCase(
    'details in a backtick fence stay text',
    'Example:\n\n```html\n'
        '<details type="reasoning" done="true">\n'
        '<summary>Thought</summary>\nhidden\n</details>\n```\n\nEnd.',
  ),
  CorpusCase(
    'details in a tilde fence stay text',
    '~~~\n<details type="tool_calls" done="true" name="x" result="y">\n'
        '</details>\n~~~',
  ),
  CorpusCase(
    'details in indented code stay text',
    'Indented:\n\n'
        '    <details type="reasoning" done="true">\n'
        '    <summary>Thought</summary>\n'
        '    </details>\n\nAfter.',
  ),
  CorpusCase(
    'details example in a fence next to a real block',
    '```\n<details type="reasoning">\n```\n\n$_reasoningWithDuration\n\nAnswer.',
  ),

  // Nesting and shapes.
  CorpusCase(
    'tool call nested in reasoning',
    '<details type="reasoning" done="true" duration="3">\n'
        '<summary>Thought for 3 seconds</summary>\n'
        'Checking the weather first.\n'
        '$_toolCallWeather\n'
        'Then deciding.\n'
        '</details>\n\nGo sailing.',
  ),
  CorpusCase(
    'generic details with a summary',
    '<details>\n<summary>Packing list</summary>\n\n- rope\n- flask\n</details>\n\n'
        'Pack light.',
  ),
  CorpusCase(
    'generic details wrapping a reasoning block',
    '<details>\n<summary>Notes</summary>\n'
        '$_reasoningWithDuration\n'
        '</details>',
  ),
  CorpusCase(
    'openai builtin tool shows as a plain section',
    '<details type="openai_builtin_tool" done="true">\n'
        '<summary>Searched the web</summary>\nthree results\n</details>\n\nDone.',
  ),
  CorpusCase(
    'closing tag followed by text on the same line',
    '<details type="reasoning" done="true" duration="1">\n'
        '<summary>Thought for 1 second</summary>\n'
        'short\n</details>The answer is &lt;b&gt;yes&lt;/b&gt;.',
  ),
  CorpusCase(
    'closing tag with trailing text between tool calls',
    '$_toolCallWeather\n'
        '<details type="tool_calls" done="true" id="call_t" name="tide_table" '
        'arguments="{}" result="&quot;06:12&quot;">\n'
        '<summary>Tool Executed</summary>\n</details>and then\n'
        '$_toolCallTides',
  ),
  CorpusCase(
    'uppercase tag with lowercase attributes',
    '<DETAILS type="reasoning" done="true" duration="5">\n'
        '<SUMMARY>Thought for 5 seconds</SUMMARY>\nloud\n</DETAILS>\n\nQuiet now.',
  ),
  CorpusCase(
    'multi-line opening tag',
    '<details type="tool_calls" done="true" id="call_m" name="note"\n'
        'arguments="{}" result="&quot;line&quot;">\n'
        '<summary>Tool Executed</summary>\n</details>\n\nNoted.',
  ),
  CorpusCase(
    'display math moves an attached opener to its own line',
    r'Energy: $$E = mc^2$$<details type="reasoning" done="true">'
        '\n<summary>Thoughts</summary>\nbody\n</details>\n\nDone.',
  ),
  CorpusCase(
    'CRLF line endings',
    '<details type="reasoning" done="true" duration="2">\r\n'
        '<summary>Thought for 2 seconds</summary>\r\n'
        '&gt; windows lines\r\n</details>\r\n\r\nAnswer.',
  ),
  CorpusCase(
    'math and prices in text',
    r'Plain currency like $65 and ~$42.6 stays prose; $x^2$ and \(y\) are math.'
        '\n\n'
        r'$$\int_0^1 x\,dx$$'
        '\n\nSee [1] and [2,3].',
  ),

  // Streaming and partial sections.
  CorpusCase(
    'unterminated reasoning while streaming',
    'Intro line.\n\n'
        '<details type="reasoning" done="false">\n'
        '<summary>Thinking…</summary>\n'
        '&gt; still writing this though',
    streaming: true,
  ),
  CorpusCase(
    'unterminated reasoning once settled',
    'Intro line.\n\n'
        '<details type="reasoning" done="false">\n'
        '<summary>Thinking…</summary>\n'
        '&gt; the stream stopped here',
  ),
  CorpusCase(
    'unterminated tool call while streaming',
    '$_reasoningWithDuration\n\n'
        '<details type="tool_calls" done="false" id="call_s" name="slow" '
        'arguments="{}">\n<summary>Executing...</summary>\n',
    streaming: true,
  ),
  CorpusCase(
    'truncated opening tag while streaming',
    'Answer so far.\n\n<details type="tool_calls" done="false" name="sl',
    streaming: true,
  ),
  CorpusCase(
    'truncated opening tag once settled',
    'Answer so far.\n\n<details type="reasoning" done="tr',
  ),
  CorpusCase(
    'complete tool call inside an unterminated reasoning while streaming',
    'Start.\n\n'
        '<details type="reasoning" done="false">\n'
        '<summary>Thinking…</summary>\n'
        '$_toolCallWeather\n'
        'more thinking',
    streaming: true,
  ),
  CorpusCase(
    'finished sections then a partial answer while streaming',
    '$_reasoningWithDuration\n$_toolCallWeather\n\nThe wind is twel',
    streaming: true,
  ),
  CorpusCase(
    'unterminated generic details while streaming stays text',
    'Look:\n\n<details>\n<summary>Open me</summary>\nstill going',
    streaming: true,
  ),
];
