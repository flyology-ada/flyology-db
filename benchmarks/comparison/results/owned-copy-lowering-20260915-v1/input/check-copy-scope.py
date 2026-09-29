#!/usr/bin/env python3
"""Check formatter scope independently of line wrapping; not a semantic proof."""
from pathlib import Path
import re

baseline = Path('src/flyology-db.adb').read_text()
candidate = Path(__file__).parent.joinpath('candidate/src/flyology-db.adb').read_text()
lexer = re.compile(r'"(?:""|[^"])*"|\x27[^\x27]\x27|--[^\n]*|[A-Za-z0-9_]+|\S')
def tokens(text):
    return [token for token in lexer.findall(text) if not token.startswith('--')]

def parts(text):
    prefix, body = text.split('   procedure Store_Mutation\n', 1)
    body, suffix = body.split('   end Store_Mutation;\n', 1)
    before, copy = body.split('      Allocation_Faults.Check (Transaction_Payload_Allocation);', 1)
    copy, after = copy.split('      System.Soft_Links.Abort_Defer.all;', 1)
    return prefix + before, copy, after + suffix

old_before, old_copy, old_after = parts(baseline)
new_before, new_copy, new_after = parts(candidate)
assert tokens(old_before) == tokens(new_before), 'code changed before copy segment'
assert tokens(old_after) == tokens(new_after), 'code changed after copy segment'
assert old_copy.count('for Offset in Natural range') == 2
assert new_copy.count('for Element of') == 2
assert 'new Ada.Streams.Stream_Element_Array' in new_copy
assert 'Item_Key\'Length > 0' in new_copy and 'Data\'Length > 0' in new_copy
assert not any(name in new_copy for name in ('Unchecked_Conversion', 'memcpy', 'pragma Suppress'))
print('COPY_SCOPE_TOKENS_BEFORE_AFTER_EQUAL')
