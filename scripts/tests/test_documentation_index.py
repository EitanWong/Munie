import importlib.util
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'check-repository.py'
SPEC = importlib.util.spec_from_file_location('documentation_checker', SCRIPT)
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class DocumentationIndexTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'docs/standards').mkdir(parents=True)
        (self.root / 'docs/README.md').write_text('[Standards](standards/README.md)\n')
        (self.root / 'docs/standards/README.md').write_text('[Parent](../README.md)\n')

    def test_index_cycles_and_encoded_topic_links_remain_discoverable(self):
        (self.root / 'docs/standards/README.md').write_text(
            '[Parent](../README.md)\n[Topic](%E5%85%A5%E5%8F%A3.md#design)\n')
        (self.root / 'docs/standards/入口.md').write_text('# Design\n')
        CHECKER.validate_documentation(self.root)

    def test_orphan_topic_requires_an_index_link(self):
        (self.root / 'docs/standards/entry.md').write_text('# Entry\n')
        with self.assertRaisesRegex(ValueError, 'Unindexed documentation: standards/entry.md'):
            CHECKER.validate_documentation(self.root)

    def test_numbered_topic_is_rejected_even_when_indexed(self):
        (self.root / 'docs/README.md').write_text('[Old](001-entry.md)\n')
        (self.root / 'docs/001-entry.md').write_text('# Entry\n')
        with self.assertRaisesRegex(ValueError, 'without a numeric prefix: 001-entry.md'):
            CHECKER.validate_documentation(self.root)

    def test_missing_root_index_fails_with_a_specific_error(self):
        (self.root / 'docs/README.md').unlink()
        with self.assertRaisesRegex(ValueError, 'Missing documentation index'):
            CHECKER.validate_documentation(self.root)

    def test_fenced_examples_do_not_index_an_orphan_topic(self):
        examples = [
            '```markdown\n[Topic](entry.md)\n```\n',
            '~~~markdown\n[Topic](entry.md)\n~~~\n',
            '````markdown\n```\n[Topic](entry.md)\n```\n````\n',
            '~~~~markdown\n~~~\n[Topic](entry.md)\n~~~\n~~~~\n',
            '   ```markdown\n[Topic](entry.md)\n   ```\n',
            '```\n~~~\n[Topic](entry.md)\n```\n',
            '```\n```not-a-closing-fence\n[Topic](entry.md)\n```\n',
            '```markdown\n[Topic](entry.md)\n',
        ]
        (self.root / 'docs/standards/entry.md').write_text('# Entry\n')
        for example in examples:
            with self.subTest(example=example):
                (self.root / 'docs/standards/README.md').write_text(example)
                with self.assertRaisesRegex(ValueError, 'Unindexed documentation: standards/entry.md'):
                    CHECKER.validate_documentation(self.root)

    def test_inline_code_examples_do_not_index_an_orphan_topic(self):
        examples = [
            '`[Topic](entry.md)`',
            '``sample ` [Topic](entry.md)``',
            '`sample\n[Topic](entry.md)`',
            '``sample `\n[Topic](entry.md)``',
        ]
        (self.root / 'docs/standards/entry.md').write_text('# Entry\n')
        for example in examples:
            with self.subTest(example=example):
                (self.root / 'docs/standards/README.md').write_text(example)
                with self.assertRaisesRegex(ValueError, 'Unindexed documentation: standards/entry.md'):
                    CHECKER.validate_documentation(self.root)

    def test_real_navigation_after_examples_still_indexes_a_topic(self):
        content = ('````markdown\n```\n[Example](missing.md)\n```\n````\n'
                   '~~~ markdown\n[Example](also-missing.md)\n~~~\n'
                   '`[Example](inline-missing.md)`\n\n'
                   '[Topic with `code` label](entry.md)\n')
        (self.root / 'docs/standards/README.md').write_text(content)
        (self.root / 'docs/standards/entry.md').write_text('# Entry\n')
        CHECKER.validate_documentation(self.root)
        self.assertEqual(CHECKER.markdown_links(content), ['entry.md'])

    def test_unmatched_or_escaped_backticks_do_not_hide_real_links(self):
        for content in ['Unclosed ` marker [Topic](entry.md)',
                        r'Escaped \`[Topic](entry.md)\`',
                        '`unclosed\n\n[Topic](entry.md)']:
            with self.subTest(content=content):
                self.assertEqual(CHECKER.markdown_links(content), ['entry.md'])


if __name__ == '__main__':
    unittest.main()
