"""워크플로우 YAML에서 블록 스칼라 하나를 그대로 떼어낸다.

왜 PyYAML을 안 쓰나: 러너에 있는지 보장되지 않고, 여기서 필요한 건 파싱이 아니라
**원문 그대로**다. YAML을 거치면 따옴표·이스케이프가 한 번 바뀌어, 테스트가 검증하는
스크립트와 실제로 도는 스크립트가 미묘하게 달라질 수 있다.

    python3 scripts/extract-block.py <파일> step   "<스텝 이름>"   > out.sh
    python3 scripts/extract-block.py <파일> input  "<입력 이름>"   > out.txt

`step`은 그 스텝의 `run:` 블록을, `input`은 그 입력의 `default:` 블록을 낸다.
"""
import io
import sys

path, kind, key = sys.argv[1], sys.argv[2], sys.argv[3]

# 표준출력을 UTF-8로 고정한다 — 원문에 한글·em dash가 있어서 콘솔 기본 인코딩(윈도의
# cp949 등)으로는 그대로 쓸 수 없다. 러너는 UTF-8이라 거기서만 돌려보면 안 걸린다.
out = io.open(sys.stdout.fileno(), 'w', encoding='utf-8', newline='')
lines = io.open(path, encoding='utf-8').read().replace('\r\n', '\n').split('\n')


def indent_of(line):
    return len(line) - len(line.lstrip(' '))


def block_after(start, marker):
    """start 이후 첫 `marker` 줄을 찾아 그 아래 들여쓰기된 블록을 돌려준다."""
    for i in range(start, len(lines)):
        stripped = lines[i].strip()
        if stripped == marker or stripped.startswith(marker + ' '):
            base = indent_of(lines[i])
            collected, j = [], i + 1
            while j < len(lines):
                if lines[j].strip() == '':
                    collected.append('')
                elif indent_of(lines[j]) > base:
                    collected.append(lines[j])
                else:
                    break
                j += 1
            # 공통 들여쓰기를 뗀다(블록 스칼라의 의미 그대로)
            widths = [indent_of(x) for x in collected if x.strip()]
            cut = min(widths) if widths else 0
            return '\n'.join(x[cut:] if x.strip() else '' for x in collected)
    raise SystemExit('블록을 못 찾음: %s (%s 이후)' % (marker, start))


if kind == 'step':
    for i, line in enumerate(lines):
        if line.strip() == '- name: ' + key or line.strip() == '- name: %s' % key:
            out.write(block_after(i, 'run:'))
            break
    else:
        raise SystemExit('스텝을 못 찾음: ' + key)
elif kind == 'input':
    for i, line in enumerate(lines):
        if line.strip() == key + ':':
            out.write(block_after(i, 'default:'))
            break
    else:
        raise SystemExit('입력을 못 찾음: ' + key)
else:
    raise SystemExit('kind는 step 또는 input')

out.flush()
