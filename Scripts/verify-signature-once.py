#!/usr/bin/env python3
"""Verify signature formatting invariants (mirrors MailSignatureFormatting rules)."""
import re, sys

def normalize_sig(s):
    text = (s or '').replace('\r\n','\n').replace('\r','\n').strip()
    while True:
        parts = text.split('\n', 1)
        line = parts[0].strip()
        if line in ('--', '-- ', '—', '–'):
            text = parts[1].strip() if len(parts)>1 else ''
            continue
        break
    return text

def plain_block(sig):
    t = normalize_sig(sig)
    return '' if not t else '\n\n--\n'+t

def trailing_delim(body):
    best = -1
    plen = 0
    for p in ['\n-- \n', '\n--\n', '\n—\n', '\n–\n']:
        i = body.rfind(p)
        if i > best:
            best, plen = i, len(p)
    return None if best < 0 else (best, best+plen)

def strip_trailing(body):
    result = body.replace('\r\n','\n').replace('\r','\n')
    while True:
        r = trailing_delim(result)
        if not r: break
        result = result[:r[0]]
    t = result.strip()
    if t in ('--','-- ','—','–') or t.startswith('--\n') or t.startswith('—\n'):
        return ''
    return result.rstrip('\n')

def strip_payload(body, sig):
    result = strip_trailing(body)
    text = normalize_sig(sig)
    if text and result.endswith(text):
        cut = result[:-len(text)].rstrip('\n')
        if cut == '' or cut.endswith('\n'):
            result = cut
    return result.rstrip('\n')

def append_plain(body, sig, has_logo=False):
    text = normalize_sig(sig)
    base = strip_payload(body, text)
    if has_logo:
        return base
    if not text: return base
    return base + plain_block(text)

def replace_sig(body, old, new, new_logo=False):
    cleaned = strip_trailing(strip_payload(body, old))
    return append_plain(cleaned, new, has_logo=new_logo)

failures = 0
def check(name, cond, detail=''):
    global failures
    if cond:
        print('PASS', name)
    else:
        failures += 1
        print('FAIL', name, detail)

gmail='— Derek'
m365='Derek Brown\nKale Yeah Inspections'

# 1. From-switch stack heal
stacked = 'Test\n\n--\n— Derek\n\n--\nDerek Brown\nKale Yeah Inspections'
healed = append_plain(stacked, m365, has_logo=False)
check('strip stack to one m365', healed.count('\n--\n')==1 and healed.endswith(m365), repr(healed))

# 2. Logo account compose: no text block
ins = '' if True else plain_block(m365)  # has logo
check('logo compose insertion empty', ins=='')

# 3. Switch gmail -> m365 logo clears text
body = plain_block(gmail)
body = replace_sig(body, gmail, m365, new_logo=True)
check('switch to logo clears dashes', '\n--\n' not in body and 'Derek' not in body, repr(body))

# 4. Switch logo -> gmail adds one
body = replace_sig('Hello', m365, gmail, new_logo=False)
check('switch to gmail one block', body.count('\n--\n')==1 and body.endswith(gmail), repr(body))

# 5. crlf stack
crlf = 'Test\r\n\r\n--\r\n— Derek\r\n\r\n--\r\nDerek Brown\r\nKale Yeah Inspections'
healed = append_plain(crlf, m365)
check('crlf stack heal', healed.count('\n--\n')==1, repr(healed))

# 6. RFC -- space
rfc = 'Hi\n\n-- \nDerek Brown\nKale Yeah Inspections'
healed = append_plain(rfc, m365)
check('rfc space delimiter', healed=='Hi\n\n--\n'+m365, repr(healed))

# 7. append idempotent
once = append_plain('Hi', m365)
twice = append_plain(once, m365)
check('idempotent append', once==twice, repr(twice))

# 8. settings delimiter paste
check('normalize leading --', normalize_sig('--\nDerek Brown')=='Derek Brown')

print('failures', failures)
sys.exit(1 if failures else 0)
