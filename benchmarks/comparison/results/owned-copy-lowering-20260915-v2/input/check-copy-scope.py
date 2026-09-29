#!/usr/bin/env python3
"""Check direct-copy edit scope, not correctness or performance."""
from pathlib import Path
import re

baseline = Path('src/flyology-db.adb').read_text()
candidate = Path(__file__).parent.joinpath('candidate/src/flyology-db.adb').read_text()
lexer = re.compile(r'"(?:""|[^"])*"|\x27[^\x27]\x27|--[^\n]*|[A-Za-z0-9_]+|\S')

def tokens(text):
    return [token for token in lexer.findall(text) if not token.startswith('--')]

def parts(text, direct=False):
    prefix, body = text.split('   procedure Store_Mutation\n', 1)
    body, suffix = body.split('   end Store_Mutation;\n', 1)
    before, copy = body.split('      Allocation_Faults.Check (Transaction_Payload_Allocation);', 1)
    copy, after = copy.split('      System.Soft_Links.Abort_Defer.all;', 1)
    helper = ''
    if direct:
        before_start, helper = before.split('      function Copy_Octets\n', 1)
        helper, before_end = helper.split('      end Copy_Into_Candidate;\n', 1)
        before = before_start + before_end
    return prefix + before, copy, after + suffix, helper

old_before, old_copy, old_after, _ = parts(baseline)
new_before, new_copy, new_after, helper = parts(candidate, True)
assert tokens(old_before) == tokens(new_before), 'non-helper code before copy changed'
assert tokens(old_after) == tokens(new_after), 'code after copy changed'
assert old_copy.count('for Offset in Natural range') == 2
assert new_copy.count('Copy_Into_Candidate') == 2
assert 'new Ada.Streams.Stream_Element_Array' in new_copy
assert "Item_Key'Length > 0" in new_copy and "Data'Length > 0" in new_copy
assert "Operation = Put_Mutation" in new_copy
assert 'Convention => C, External_Name => "memcpy"' in helper
assert "System.Storage_Unit = 8" in helper
assert "Byte_Array'Component_Size = 8" in helper
assert "Ada.Streams.Stream_Element_Array'Component_Size = 8" in helper
assert "Interfaces.C.size_t'Size >= Natural'Size" in helper
assert "if Source'Length = 0 then" in helper
assert "Source (Source'First)'Address" in helper
assert "Interfaces.C.size_t (Source'Length)" in helper
assert 'for Offset in Natural range' in helper
assert not any(name in helper for name in ('Unchecked_Conversion', 'pragma Suppress'))
print('DIRECT_COPY_SCOPE_TOKENS_BEFORE_AFTER_EQUAL')
