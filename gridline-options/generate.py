from pathlib import Path
from html import escape

root = Path(__file__).parent
parts = []
def text(x, y, value, size=12, fill='#667085', weight=400, anchor='start'):
    parts.append(f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" font-weight="{weight}" text-anchor="{anchor}">{escape(value)}</text>')

def chart(x, y, count, values, dividers, labels):
    width, height = 320, 82
    parts.append(f'<rect x="{x-18}" y="{y-16}" width="356" height="142" rx="12" fill="#f5f6f8"/>')
    # Gap midpoint: painted bar ends at 90% of its interval, then the next begins.
    for index in [0, *dividers, count]:
        position = x + width * (index if index in (0, count) else index - .05) / count
        parts.append(f'<line x1="{position}" y1="{y}" x2="{position}" y2="{y+height}" stroke="#aeb6c2" stroke-width="1" stroke-dasharray="3 4"/>')
    for index, value in enumerate(values):
        bx = x + width * index / count
        bh = height * value
        parts.append(f'<rect x="{bx}" y="{y+height-bh}" width="{width*.9/count}" height="{bh}" fill="#6b9ffa"/>')
    for index, label in labels:
        text(x + width * (index + .45) / count, y + height + 23, label, size=12, anchor='middle', fill='#69717d')

text(28, 32, 'Gridline comparison', 21, '#1f2937', 650)
text(28, 55, 'Sketch · identical bars and captions in both columns', 12)
text(40, 91, '1 · Even groups, snapped to gaps', 14, '#1f2937', 600)
text(420, 91, '3 · Fixed cadence per period', 14, '#1f2937', 600)

scenarios = [
    ('Today · 24 hourly bars', 24, [.30 + .6*(i%12)/11 for i in range(24)],
     [8,16], [6,12,18], [(0,'00'),(8,'08'),(15,'15'),(23,'23')],
     'Three groups of 8 hours', 'Four groups of 6 hours'),
    ('7 days · 7 daily bars', 7, [.9,.82,.72,.79,.61,.67,.45],
     [2,5], [2,4,6], [(0,'2 Oct'),(2,'4 Oct'),(4,'6 Oct'),(6,'8 Oct')],
     'Groups of 2 / 3 / 2 days', 'Groups of 2 / 2 / 2 / 1 days'),
    ('30 days · 30 daily bars', 30, [.32+.56*((i*3+4)%11)/10 for i in range(30)],
     [10,20], [7,14,21,28], [(0,'9 Sep'),(10,'19 Sep'),(19,'28 Sep'),(29,'8 Oct')],
     'Three groups of 10 days', 'Groups of 7 / 7 / 7 / 7 / 2 days'),
]
for row, (title, count, values, even, cadence, labels, leftnote, rightnote) in enumerate(scenarios):
    top = 128 + row*190
    text(28, top, title, 13, '#344054', 600)
    chart(40, top+27, count, values, even, labels)
    chart(420, top+27, count, values, cadence, labels)
    text(40, top+172, leftnote, 11)
    text(420, top+172, rightnote, 11)
text(28, 720, 'Interior lines sit in real bar gaps. Outer lines sit at the plot edges.', 12)
svg = '<svg xmlns="http://www.w3.org/2000/svg" width="780" height="744" viewBox="0 0 780 744"><style>text{font-family:-apple-system,BlinkMacSystemFont,Arial,sans-serif}</style><rect width="780" height="744" fill="white"/>' + ''.join(parts) + '</svg>'
(root/'comparison.svg').write_text(svg)
(root/'index.html').write_text('<!doctype html><html><head><meta charset="utf-8"><title>Gridline sketches</title><style>body{margin:0;background:white}svg{display:block}</style></head><body>'+svg+'</body></html>')
