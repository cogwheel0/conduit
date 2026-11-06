import 'package:checks/checks.dart';
import 'package:conduit_core/features/notes/utils/note_page_data.dart';
import 'package:test/test.dart';

Map<String, dynamic> page(String id, String md) => <String, dynamic>{
  'id': id,
  'title': id,
  'content': <String, dynamic>{'json': null, 'html': '', 'md': md},
};

void main() {
  group('page shape', () {
    test('a note without pages saves to the main page', () {
      final data = <String, dynamic>{
        'content': <String, dynamic>{'md': 'x'},
      };
      check(noteDataHasPages(data)).isFalse();
      check(noteDataIsMultiPage(data)).isFalse();
      check(noteSinglePageId(data)).equals(kNoteMainPageId);
    });

    test('a single-page note saves to its page', () {
      final data = <String, dynamic>{
        'pages': [page('main', 'x')],
      };
      check(noteDataHasPages(data)).isTrue();
      check(noteSinglePageId(data)).equals('main');
    });

    test('a note with several pages has no single page to save to', () {
      final data = <String, dynamic>{
        'pages': [page('main', 'x'), page('p2', 'y')],
      };
      check(noteDataIsMultiPage(data)).isTrue();
      check(noteSinglePageId(data)).isNull();
    });

    test('a create leaves out what the server derives from pages', () {
      final data = noteDataForCreate(<String, dynamic>{
        'content': <String, dynamic>{'md': 'x'},
        'files': null,
        'pages': [page('main', 'x')],
        'pages_revision': 2,
        'search_text': 'x',
      });
      check(data.keys.toSet()).deepEquals({'content', 'files'});
    });
  });

  group('content edits', () {
    test('merge over a note in the older shape', () {
      final data = applyNoteContentEdit(
        <String, dynamic>{
          'content': <String, dynamic>{'md': 'old'},
          'files': <Object>[],
        },
        <String, dynamic>{
          'content': <String, dynamic>{'md': 'new'},
        },
      );
      check(data).deepEquals(<String, dynamic>{
        'content': <String, dynamic>{'md': 'new'},
        'files': <Object>[],
      });
    });

    test('go to the only page of a paged note and mark it edited', () {
      final data = applyNoteContentEdit(
        <String, dynamic>{
          'content': <String, dynamic>{'md': 'old'},
          'pages': [page('main', 'old')],
        },
        <String, dynamic>{
          'content': <String, dynamic>{'md': 'new'},
        },
      );
      check(notePageMarkdown(data, 'main')).equals('new');
      check((data['content'] as Map)['md']).equals('new');
      check(noteDirtyPageIds(data)).deepEquals(['main']);
    });

    test('go to the named page of a note with several pages', () {
      final data = applyNoteContentEdit(
        <String, dynamic>{
          'content': <String, dynamic>{'md': '## main\n\na\n\n## p2\n\nb'},
          'pages': [page('main', 'a'), page('p2', 'b')],
          kNoteDirtyPagesKey: ['main'],
        },
        <String, dynamic>{
          'content': <String, dynamic>{'md': 'B'},
        },
        pageId: 'p2',
      );
      check(notePageMarkdown(data, 'main')).equals('a');
      check(notePageMarkdown(data, 'p2')).equals('B');
      // The combined view stays the server's until it answers.
      check((data['content'] as Map)['md']).isA<String>().startsWith('## main');
      check(noteDirtyPageIds(data)).deepEquals(['main', 'p2']);
    });

    test('refuse content that names no page of a note with several pages', () {
      final data = <String, dynamic>{
        'pages': [page('main', 'a'), page('p2', 'b')],
      };
      check(
        () => applyNoteContentEdit(data, <String, dynamic>{
          'content': <String, dynamic>{'md': 'x'},
        }),
      ).throws<NotePageRequiredException>();
      check(
        () => applyNoteContentEdit(data, <String, dynamic>{
          'content': <String, dynamic>{'md': 'x'},
        }, pageId: 'gone'),
      ).throws<NotePageMissingException>();
    });

    test('a create leaves out the edited-pages mark', () {
      check(
        noteDataForCreate(<String, dynamic>{
          'content': <String, dynamic>{'md': 'x'},
          kNoteDirtyPagesKey: ['main'],
        }).keys.toSet(),
      ).deepEquals({'content'});
    });
  });

  group('update body', () {
    test('sends the content, and a file list only when given', () {
      final body = noteContentUpdateBody(
        <String, dynamic>{'md': 'x'},
        pageId: 'main',
        files: <Object>[],
      );
      check(body['page_id']).equals('main');
      check((body['data'] as Map).keys.toSet())
          .deepEquals({'content', 'files'});
      check(
        (noteContentUpdateBody(<String, dynamic>{
                  'md': 'x',
                }, pageId: 'p2')['data']
                as Map)
            .keys
            .toSet(),
      ).deepEquals({'content'});
    });

    test('moving files into the content links each one once and resolves '
        'images', () {
      final content = noteContentWithLinkedFiles(
        <String, dynamic>{
          'json': null,
          'html': '',
          'md': 'a ![pic](data://i1)\n\n[Old](/api/v1/files/f0/content)',
        },
        <Object>[
          <String, dynamic>{'type': 'file', 'id': 'f0', 'name': 'Old'},
          <String, dynamic>{'type': 'file', 'id': 'f1', 'name': 'New'},
          <String, dynamic>{'type': 'image', 'id': 'i1', 'url': '/img/1'},
        ],
      );
      check(content['md']).equals(
        'a ![pic](/img/1)\n\n[Old](/api/v1/files/f0/content)\n\n'
        '[New](/api/v1/files/f1/content)',
      );
      // Empty html is left for the server to derive from the markdown.
      check(content['json']).isNull();
      check(content['html']).equals('');
    });

    test('moving files into rich content keeps its html and editor json, '
        'adding each file to both as the server does', () {
      final content = noteContentWithLinkedFiles(
        <String, dynamic>{
          'json': <String, dynamic>{
            'type': 'doc',
            'content': <Object>[
              <String, dynamic>{
                'type': 'image',
                'attrs': <String, dynamic>{'src': 'data://i1'},
              },
            ],
          },
          'html': '<p><strong>a</strong></p><img src="data://i1">',
          'md': 'a',
        },
        <Object>[
          <String, dynamic>{
            'type': 'file',
            'id': 'f1',
            'name': 'R & D',
            'size': 7,
          },
          <String, dynamic>{'type': 'image', 'id': 'i1', 'url': '/img/1'},
        ],
      );

      check(content['md']).equals('a\n\n[R & D](/api/v1/files/f1/content)');
      check(content['html']).equals(
        '<p><strong>a</strong></p><img src="/img/1">'
        '<div data-file-id="f1"><a href="/api/v1/files/f1/content">'
        'R &amp; D</a></div>',
      );
      final nodes = (content['json'] as Map)['content'] as List;
      check((nodes.first as Map)['attrs']).isA<Map>().deepEquals({
        'src': '/img/1',
      });
      check(nodes.last).isA<Map>().deepEquals({
        'type': 'fileAttachment',
        'attrs': {'id': 'f1', 'name': 'R & D', 'size': 7},
      });
    });

    test('a file linked only where the server does not read it is added to '
        'the editor json, once in each form', () {
      const link = '[F](/api/v1/files/f1/content)';
      const html = '<p><a href="/api/v1/files/f1/content">F</a></p>';
      final content = noteContentWithLinkedFiles(
        <String, dynamic>{
          'json': <String, dynamic>{'type': 'doc', 'content': <Object>[]},
          'html': html,
          'md': link,
        },
        <Object>[
          <String, dynamic>{'type': 'file', 'id': 'f1', 'name': 'F'},
        ],
      );

      check(content['md']).equals(link);
      check(content['html']).equals(html);
      check(((content['json'] as Map)['content'] as List).single)
          .isA<Map>()
          .has((node) => node['type'], 'type')
          .equals('fileAttachment');
    });

    test('html that names a file outside an anchor does not attach it', () {
      final content = noteContentWithLinkedFiles(
        <String, dynamic>{
          'json': null,
          'html': '<p>see href="/api/v1/files/f1/content"</p>',
          'md': 'see',
        },
        <Object>[
          <String, dynamic>{'type': 'file', 'id': 'f1', 'name': 'F'},
        ],
      );

      check(content['md']).equals('see\n\n[F](/api/v1/files/f1/content)');
      check(content['html'] as String).contains('<a href=');
    });

    test('a file the editor json attaches already is not added again', () {
      final original = <String, dynamic>{
        'json': <String, dynamic>{
          'type': 'doc',
          'content': <Object>[
            <String, dynamic>{
              'type': 'fileAttachment',
              'attrs': <String, dynamic>{'id': 'a', 'name': 'A'},
            },
          ],
        },
        'html': '<p>x</p>',
        'md': 'x',
      };
      check(
        identical(
          noteContentWithLinkedFiles(original, <Object>[
            <String, dynamic>{'type': 'file', 'id': 'a', 'name': 'A'},
          ]),
          original,
        ),
      ).isTrue();
    });

    test('content already linking every file is left alone', () {
      // Content as Conduit writes it: the markdown is what the server reads.
      final original = <String, dynamic>{
        'json': null,
        'html': '',
        'md': '[A](/api/v1/files/a/content)',
      };
      check(
        identical(
          noteContentWithLinkedFiles(original, <Object>[
            <String, dynamic>{'type': 'file', 'id': 'a', 'name': 'A'},
          ]),
          original,
        ),
      ).isTrue();
    });
  });

  group('file links', () {
    test('are read from markdown in order, each id once', () {
      const md =
          'intro [doc](https://example.com)\n\n'
          '[A.m4a](/api/v1/files/a-1/content)\n\n'
          'see [again](/api/v1/files/a-1/content) and '
          '[](/api/v1/files/b_2/content)';
      check(noteFileLinksInMarkdown(md)).deepEquals([
        const NoteFileLink(id: 'a-1', name: 'A.m4a'),
        const NoteFileLink(id: 'b_2', name: 'b_2'),
      ]);
    });

    test('are written as the server writes them', () {
      check(noteFileLinkMarkdown(id: 'f1', name: 'Take [2]'))
          .equals('[Take 2](/api/v1/files/f1/content)');
      check(
        appendNoteFileLinks('', <Map<String, dynamic>>[
          <String, dynamic>{'type': 'file', 'id': 'f1', 'name': 'R'},
        ]),
      ).equals('\n\n[R](/api/v1/files/f1/content)');
    });

    test('removing one takes its line and paragraph break', () {
      const md =
          'a\n\n[A](/api/v1/files/f1/content)\n\nb\n\n'
          '[B](/api/v1/files/f2/content)\n';
      check(removeNoteFileLinks(md, 'f1'))
          .equals('a\n\nb\n\n[B](/api/v1/files/f2/content)\n');
      check(removeNoteFileLinks(md, 'f2'))
          .equals('a\n\n[A](/api/v1/files/f1/content)\n\nb\n');
    });

    test('leave out images and code, as the server does', () {
      const md =
          '![pic](/api/v1/files/img/content)\n'
          '`[x](/api/v1/files/code/content)`\n'
          '```\n[y](/api/v1/files/fenced/content)\n```\n'
          '[real](/api/v1/files/real/content)';
      check(noteFileLinksInMarkdown(md).map((link) => link.id))
          .deepEquals(['real']);
    });

    test('a merge keeps links the stored page gained, not ones removed', () {
      const a = '[A](/api/v1/files/a/content)';
      const b = '[B](/api/v1/files/b/content)';
      // B was attached while the editor held its copy; the user removed A.
      check(
        mergeNoteFileLinks(
          base: 'text\n\n$a',
          stored: 'text\n\n$a\n\n$b',
          mine: 'text edited',
        ),
      ).equals('text edited\n\n$b');
      check(mergeNoteFileLinks(base: 'x', stored: 'x', mine: 'y')).equals('y');
    });

    test('removing one inside a sentence keeps the sentence', () {
      check(removeNoteFileLinks('see [A](/api/v1/files/f1/content) here', 'f1'))
          .equals('see  here');
    });
  });

  group('older edits and copies', () {
    test('a one-page note\'s text is its content, which earlier builds '
        'edited', () {
      final data = <String, dynamic>{
        'content': <String, dynamic>{'md': 'edited'},
        'pages': [page('main', 'stale')],
      };
      check(notePageMarkdown(data, 'main')).equals('edited');
    });

    test('the combined view names each page by its path', () {
      final pages = [
        page('main', 'a'),
        {...page('p2', 'b'), 'title': 'Two'},
        {...page('p3', 'c'), 'title': 'Sub', 'parent_id': 'p2'},
      ];
      check(noteCombinedMarkdown(pages))
          .equals('## main\n\na\n\n## Two\n\nb\n\n## Two / Sub\n\nc');
      check(
        noteCombinedContentEdited(<String, dynamic>{
          'content': <String, dynamic>{'md': noteCombinedMarkdown(pages)},
          'pages': pages,
        }),
      ).isFalse();
      check(
        noteCombinedContentEdited(<String, dynamic>{
          'content': <String, dynamic>{'md': 'edited'},
          'pages': pages,
        }),
      ).isTrue();
    });

    test('a conflict copy holds the edited page, without pages', () {
      final copy = noteDataForConflictCopy(<String, dynamic>{
        'content': <String, dynamic>{'md': '## combined'},
        'pages': [page('main', 'a'), page('p2', 'b edited')],
        'pages_revision': 1,
        kNoteDirtyPagesKey: ['p2'],
      });
      check(copy.keys.toSet()).deepEquals({'content'});
      check((copy['content'] as Map)['md']).equals('b edited');
    });

    test(
      'a conflict copy of several edited pages puts each under its title',
      () {
        final copy = noteDataForConflictCopy(<String, dynamic>{
          'content': <String, dynamic>{'md': '## combined'},
          'pages': [page('main', 'a'), page('p2', 'b'), page('p3', 'c')],
          kNoteDirtyPagesKey: ['p3', 'main'],
        });
        check((copy['content'] as Map)['md'])
            .equals('## main\n\na\n\n## p3\n\nc');
      },
    );

    test('detaching a file takes it out of the list and the text', () {
      const link = '[F](/api/v1/files/f/content)';
      final legacy = noteDataWithoutFile(<String, dynamic>{
        'content': <String, dynamic>{'md': 'x\n\n$link'},
        'files': [
          <String, dynamic>{'id': 'f'},
          <String, dynamic>{'id': 'g'},
        ],
      }, 'f');
      check(legacy['files'] as List).length.equals(1);
      check((legacy['content'] as Map)['md']).equals('x');

      final paged = noteDataWithoutFile(<String, dynamic>{
        'content': <String, dynamic>{'md': 'x\n\n$link'},
        'pages': [page('main', 'x\n\n$link')],
        'files': [
          <String, dynamic>{'id': 'f'},
        ],
      }, 'f');
      check(paged.keys.toSet()).deepEquals({'content'});
      check(
        noteDataWithoutFile(<String, dynamic>{
          'content': <String, dynamic>{'md': 'x'},
        }, 'f'),
      ).isEmpty();
    });

    test('detaching a file keeps the rich text the web editor saved', () {
      const href = '/api/v1/files/f/content';
      final linked = noteContentWithLinkedFiles(<String, dynamic>{
        'md': 'hello',
        'html': '<p><strong>hello</strong></p>',
        'json': <String, dynamic>{
          'type': 'doc',
          'content': [
            <String, dynamic>{
              'type': 'paragraph',
              'content': [
                <String, dynamic>{
                  'type': 'text',
                  'text': 'hello',
                  'marks': [
                    <String, dynamic>{'type': 'bold'},
                  ],
                },
                <String, dynamic>{
                  'type': 'text',
                  'text': ' see F',
                  'marks': [
                    <String, dynamic>{
                      'type': 'link',
                      'attrs': <String, dynamic>{'href': href},
                    },
                  ],
                },
              ],
            },
          ],
        },
      }, [
        <String, dynamic>{'type': 'file', 'id': 'f', 'name': 'F'},
      ]);
      check(linked['html'] as String).contains('data-file-id="f"');

      // Detaching it from a page goes the same way.
      final patch = noteDataWithoutFile(<String, dynamic>{
        'content': linked,
        'pages': [
          <String, dynamic>{'id': 'main', 'title': 'Main', 'content': linked},
        ],
      }, 'f');
      check(
        (patch['content'] as Map)['html'],
      ).equals('<p><strong>hello</strong></p>');

      final content = noteContentWithoutFile(linked, 'f');
      check(content['md']).equals('hello');
      check(content['html']).equals('<p><strong>hello</strong></p>');
      check(content['json']).isA<Map<String, dynamic>>().deepEquals({
        'type': 'doc',
        'content': [
          {
            'type': 'paragraph',
            'content': [
              {
                'type': 'text',
                'text': 'hello',
                'marks': [
                  {'type': 'bold'},
                ],
              },
            ],
          },
        ],
      });
    });

    test('a form that still links a detached file in a shape not known is '
        'cleared, so the server stops reading the file from it', () {
      final content = noteContentWithoutFile(<String, dynamic>{
        'md': 'x\n\n[F](/api/v1/files/f/content)',
        // An anchor whose markup the remover does not take out.
        'html': '<p>x</p><a data-x="<" href="/api/v1/files/f/content">F</a',
        'json': null,
      }, 'f');
      check(content['md']).equals('x');
      check(content['html']).equals('');
    });

    test('a file linked only in the rich text is detached too', () {
      Map<String, dynamic> paged(Map<String, dynamic> content) =>
          <String, dynamic>{
            'content': content,
            'pages': [
              <String, dynamic>{'id': 'main', 'title': 'Main', 'content': content},
            ],
          };
      // The editor JSON names the file; the markdown does not.
      final fromJson = noteDataWithoutFile(
        paged(<String, dynamic>{
          'md': 'x',
          'html': '',
          'json': <String, dynamic>{
            'type': 'doc',
            'content': [
              <String, dynamic>{
                'type': 'fileAttachment',
                'attrs': <String, dynamic>{'id': 'f'},
              },
            ],
          },
        }),
        'f',
      );
      check(
        ((fromJson['content'] as Map)['json'] as Map)['content'] as List,
      ).isEmpty();
      // Only the HTML links it.
      final fromHtml = noteDataWithoutFile(
        paged(<String, dynamic>{
          'md': 'x',
          'html': '<p>x</p><a href="/api/v1/files/f/content">F</a>',
          'json': null,
        }),
        'f',
      );
      check((fromHtml['content'] as Map)['html']).equals('<p>x</p>');
    });

    test('detaching a file takes out its own links, not those of a file '
        'whose id differs only in case', () {
      final content = noteContentWithoutFile(<String, dynamic>{
        'md': '',
        'html':
            '<a href="/api/v1/files/FileA/content">A</a>'
            '<div data-file-id="filea"><a href="/api/v1/files/filea/content">'
            'a</a></div>',
        'json': null,
      }, 'FileA');
      check(content['html']).equals(
        '<div data-file-id="filea"><a href="/api/v1/files/filea/content">'
        'a</a></div>',
      );
    });

    test('a block holding more than a detached file\'s link keeps the rest, '
        'and no longer names the file', () {
      final content = noteContentWithoutFile(<String, dynamic>{
        'md': 'x\n\n[F](/api/v1/files/f/content)',
        'html':
            '<p>x</p>'
            '<div class="callout" data-file-id="f" data-file-size="3" '
            'style="color: red"><div><p>kept</p></div>'
            '<a href="/api/v1/files/f/content">F</a></div>'
            '<p>after</p>'
            '<div data-file-id="g"><a href="/api/v1/files/g/content">G</a></div>',
        'json': null,
      }, 'f');
      check(content['html']).equals(
        '<p>x</p><div class="callout" style="color: red"><div><p>kept</p>'
        '</div></div><p>after</p>'
        '<div data-file-id="g"><a href="/api/v1/files/g/content">G</a></div>',
      );
    });

    test('a block naming a detached file whose link is to another file keeps '
        'that link', () {
      final content = noteContentWithoutFile(<String, dynamic>{
        'md': '',
        'html':
            '<a href="/api/v1/files/f/content">F</a>'
            '<div data-file-id="f"><a href="/api/v1/files/g/content">G</a></div>',
        'json': null,
      }, 'f');
      check(
        content['html'],
      ).equals('<div><a href="/api/v1/files/g/content">G</a></div>');
    });

    test('a block of only a detached file\'s link goes whole, with the space '
        'around its link', () {
      final content = noteContentWithoutFile(<String, dynamic>{
        'md': '',
        'html':
            '<p>x</p><DIV data-file-id="f" data-file-size="3">\n  '
            '<a href="/api/v1/files/f/content">F</a>\n</DIV><p>y</p>',
        'json': null,
      }, 'f');
      check(content['html']).equals('<p>x</p><p>y</p>');
    });

    test('tilde fences hide links too', () {
      check(
        noteFileLinksInMarkdown(
          '~~~\n[a](/api/v1/files/a/content)\n~~~\n'
          '[b](/api/v1/files/b/content)',
        ).map((link) => link.id),
      ).deepEquals(['b']);
    });
  });

  group('code', () {
    test('a link added after an unclosed code block closes the block first', () {
      final md = appendNoteFileLinks('```\ncode', <Map<String, dynamic>>[
        <String, dynamic>{'type': 'file', 'id': 'f1', 'name': 'R'},
      ]);
      check(noteFileLinksInMarkdown(md).map((link) => link.id)).deepEquals([
        'f1',
      ]);
      check(md).startsWith('```\ncode\n```');
    });

    test('a code block closes only on a fence of its own kind and length', () {
      // The ``` and ~~~~ lines sit inside blocks they do not close.
      const md =
          '~~~\n```\n[a](/api/v1/files/a/content)\n~~~\n'
          '````\n```\n[b](/api/v1/files/b/content)\n````\n'
          '[c](/api/v1/files/c/content)';
      check(noteFileLinksInMarkdown(md).map((link) => link.id)).deepEquals([
        'c',
      ]);
      check(removeNoteFileLinks(md, 'a')).equals(md);
    });

    test('fences are found on lines that end in CRLF', () {
      check(
        noteFileLinksInMarkdown(
          '~~~\r\n[a](/api/v1/files/a/content)\r\n~~~\r\n'
          '[b](/api/v1/files/b/content)',
        ).map((link) => link.id),
      ).deepEquals(['b']);
      final md = appendNoteFileLinks('```\r\ncode', <Map<String, dynamic>>[
        <String, dynamic>{'type': 'file', 'id': 'f1', 'name': 'R'},
      ]);
      check(noteFileLinksInMarkdown(md).map((link) => link.id)).deepEquals([
        'f1',
      ]);
    });

    test('a fence indented four spaces is code, not a fence', () {
      check(
        noteFileLinksInMarkdown(
          '~~~\r\n    ~~~\r\n[x](/api/v1/files/inner/content)\r\n~~~\r\n'
          '[real](/api/v1/files/real/content)',
        ).map((link) => link.id),
      ).deepEquals(['real']);
    });

    test('text with lone carriage returns is not read as an open block', () {
      final md = appendNoteFileLinks('~~~\rinside\r~~~\rtext', [
        <String, dynamic>{'type': 'file', 'id': 'f1', 'name': 'R'},
      ]);
      check(md).equals(
        '~~~\rinside\r~~~\rtext\n\n[R](/api/v1/files/f1/content)',
      );
      check(noteFileLinksInMarkdown(md).map((link) => link.id)).deepEquals([
        'f1',
      ]);
    });

    test('a closer with text after it leaves the block open', () {
      check(
        noteFileLinksInMarkdown(
          '```\n``` not a closer\n[a](/api/v1/files/a/content)\n```',
        ),
      ).isEmpty();
    });

    test('backticks with a backtick after them open no block', () {
      check(
        noteFileLinksInMarkdown(
          '``` `x` ```\n[a](/api/v1/files/a/content)',
        ).map((link) => link.id),
      ).deepEquals(['a']);
    });

    test('a link added after an unclosed longer fence closes it in kind', () {
      final md = appendNoteFileLinks('````\n```\ncode', <Map<String, dynamic>>[
        <String, dynamic>{'type': 'file', 'id': 'f1', 'name': 'R'},
      ]);
      check(noteFileLinksInMarkdown(md).map((link) => link.id)).deepEquals([
        'f1',
      ]);
      check(md).startsWith('````\n```\ncode\n````');
    });

    test('a link whose name holds inline code is a link, and can be removed',
        () {
      const md = 'see [`report`.pdf](/api/v1/files/f/content) here';
      check(noteFileLinksInMarkdown(md).map((link) => link.id)).deepEquals([
        'f',
      ]);
      check(removeNoteFileLinks(md, 'f')).equals('see  here');
    });

    test('links in double-backtick or multiline code spans are code', () {
      const md =
          '``[a](/api/v1/files/a/content)``\n'
          'text `one\n[c](/api/v1/files/c/content) two` more\n'
          '[b](/api/v1/files/b/content)';
      check(noteFileLinksInMarkdown(md).map((link) => link.id)).deepEquals([
        'b',
      ]);
      check(removeNoteFileLinks(md, 'a')).equals(md);
      check(removeNoteFileLinks(md, 'c')).equals(md);
    });

    test('a backtick left open does not hide the next paragraph', () {
      check(
        noteFileLinksInMarkdown(
          'a `x\n\n[b](/api/v1/files/b/content) and `y',
        ).map((link) => link.id),
      ).deepEquals(['b']);
    });

    test('an address a code span breaks is no link', () {
      const md = 'x [a](/api/v1/files/`y`f/content)';
      check(noteFileLinksInMarkdown(md)).isEmpty();
      final appended = appendNoteFileLinks(md, [
        <String, dynamic>{'type': 'file', 'id': 'f', 'name': 'F'},
      ]);
      check(noteFileLinksInMarkdown(appended).map((l) => l.id)).deepEquals([
        'f',
      ]);
    });

    test('removing a file keeps the same link quoted in inline code', () {
      const quoted = '`[x](/api/v1/files/f1/content)`';
      check(
        removeNoteFileLinks(
          'see $quoted and [R](/api/v1/files/f1/content)',
          'f1',
        ),
      ).equals('see $quoted and ');
    });
  });
}
