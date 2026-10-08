from pathlib import Path
import sys
from PIL import Image, ImageChops

# Coordinates apply to the matched 720x978 native captures from this verification setup.
root = Path(sys.argv[1])
for period in ['today', 'week', 'month']:
    before = Image.open(root / f'before-{period}.png').convert('RGB')
    after = Image.open(root / f'after-{period}.png').convert('RGB')
    assert before.size == after.size == (720, 978)
    region = (0, 795, 720, 832)
    assert ImageChops.difference(before.crop(region), after.crop(region)).getbbox() is None, period
    print(f'{period}: native caption pixels unchanged')
