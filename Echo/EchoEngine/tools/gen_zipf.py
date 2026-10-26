# Generates EchoEngine's word-frequency table from the wordfreq package.
# Usage: python3 -m venv venv && venv/bin/pip install wordfreq && venv/bin/python tools/gen_zipf.py Sources/EchoEngine/Resources/zipf-en.tsv
import re, sys, wordfreq
ok = re.compile(r"^[a-z]+(?:['-][a-z]+)*$")
rows = []
for w in wordfreq.top_n_list("en", 1_000_000):
    if not ok.match(w): continue
    z = wordfreq.zipf_frequency(w, "en")
    if z < 1.5: break
    rows.append(f"{w}\t{round(z*100)}")
with open(sys.argv[1], "w") as f:
    f.write("# English Zipf frequencies (x100) from wordfreq " + wordfreq.__version__ if hasattr(wordfreq, "__version__") else "3.1.1" + " (data CC BY-SA 4.0, https://github.com/rspeer/wordfreq). One word per line: word<TAB>zipf*100.\n")
    f.write("\n".join(rows) + "\n")
print(len(rows))
