#!/usr/bin/env python3
"""Repair only the template boot cells, then scale non-torso cells in code.

This intentionally edits a marked guide, never production textures or rig data.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image

from armk_atlas_test import CELL_NAMES, ROW_CELL_COUNTS, assign_marker_cells, contiguous_bands, detect_markers

EXPECTED = [1, 5, 2, 1, 1, 2, 2, 2, 2, 1, 2, 1]


def gutter_bands(values, threshold):
    # Anti-aliased gutter strokes can contain short gaps in their white core.
    result = []
    for band in contiguous_bands(values.tolist(), threshold):
        if result and band['start']-result[-1]['end'] <= 4:
            result[-1]['end'] = band['end']
        else:
            result.append(dict(band))
    return result


def detect_cells(image):
    white = np.all(np.asarray(image.convert('RGB')) >= 245, axis=2)
    height, width = white.shape
    bands = gutter_bands(white.sum(axis=1), int(width*.75))
    inner = [b for b in bands if b['start'] > 4 and b['end'] < height-4]
    if len(inner) != 3:
        raise ValueError(f'Expected three horizontal gutters: {inner}')
    row_spans = [(0, inner[0]['start']), (inner[0]['end'], inner[1]['start']),
                 (inner[1]['end'], inner[2]['start']), (inner[2]['end'], height)]
    cells = []
    for row, (y0, y1) in enumerate(row_spans):
        vertical = gutter_bands(white[y0:y1].sum(axis=0), int((y1-y0)*.75))
        if len(vertical) != ROW_CELL_COUNTS[row]+1:
            raise ValueError(f'Unexpected vertical gutters in row {row}: {vertical}')
        for column in range(ROW_CELL_COUNTS[row]):
            cells.append({'name': CELL_NAMES[len(cells)], 'row': row, 'column': column,
                          'rect': [vertical[column]['end'], y0, vertical[column+1]['start'], y1]})
    return cells


def markers_by_cell(image, cells):
    markers = detect_markers(image)
    assigned = assign_marker_cells(markers, cells)
    counts = [len(assigned[cell['name']]) for cell in cells]
    if counts != EXPECTED:
        raise ValueError(f'Expected 22 anatomical markers distributed {EXPECTED}, got {counts}')
    return assigned


def content_rect(image, bounds):
    rect = list(bounds)
    while sum(min(image.getpixel((x, rect[1]))) >= 230 for x in range(rect[0], rect[2])) >= .98*(rect[2]-rect[0]):
        rect[1] += 1
    while sum(min(image.getpixel((x, rect[3]-1))) >= 230 for x in range(rect[0], rect[2])) >= .98*(rect[2]-rect[0]):
        rect[3] -= 1
    return rect


def artwork_bounds(image):
    rgb = np.asarray(image.convert('RGB'), dtype=np.int16)
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    magenta = (r >= 12) & (b >= 12) & (g <= 245) & (np.minimum(r, b) - g >= 8) & (np.abs(r-b) <= 75)
    white = np.all(rgb >= 230, axis=2)
    ys, xs = np.nonzero(~magenta & ~white)
    return [int(xs.min()), int(ys.min()), int(xs.max()+1), int(ys.max()+1)]


def flat_cell_background(image):
    rgb = np.array(image, dtype=np.int16)
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    magenta = (r >= 12) & (b >= 12) & (g <= 245) & (np.minimum(r, b)-g >= 8) & (np.abs(r-b) <= 75)
    # Remove only the light gutter fringe at the crop perimeter, never the
    # character's white wraps or internal highlights. Otherwise resizing an
    # anti-aliased gutter pixel introduces unwanted inner white rectangles.
    perimeter = np.zeros(rgb.shape[:2], dtype=bool)
    perimeter[:4] = perimeter[-4:] = True
    perimeter[:, :4] = perimeter[:, -4:] = True
    fringe = perimeter & np.all(rgb >= 230, axis=2)
    rgb[magenta | fringe] = (255, 0, 255)
    return Image.fromarray(rgb.astype(np.uint8))


def run(original_path, generated_path, output_dir, factor):
    original = Image.open(original_path).convert('RGB')
    generated = Image.open(generated_path).convert('RGB')
    if original.size != (1024, 1536) or generated.size != original.size:
        raise ValueError(f'Exact 1024x1536 inputs required: {original.size}, {generated.size}')
    if not 0 < factor <= 1:
        raise ValueError('Factor must be positive and at most one')
    cells = detect_cells(original)
    generated_cells = detect_cells(generated)
    # Only the bottom cells are copied from the generated result. Discard all
    # generator changes, including one-pixel gutter drift, in other rows.
    if [c['rect'] for c in generated_cells if c['row'] == 3] != [c['rect'] for c in cells if c['row'] == 3]:
        raise ValueError('Generated gutters changed; do not silently remap the atlas')
    markers_by_cell(original, cells)
    markers_by_cell(generated, cells)
    corrected = original.copy()
    for cell in cells:
        if cell['row'] == 3:
            rect = tuple(content_rect(original, cell['rect']))
            corrected.paste(generated.crop(rect), rect[:2])
    # Everything above the edited boot/shin row must remain byte-for-byte original.
    row_start = min(c['rect'][1] for c in cells if c['row'] == 3)
    assert np.array_equal(np.asarray(original)[:row_start], np.asarray(corrected)[:row_start])
    before_markers = markers_by_cell(corrected, cells)
    resized = corrected.copy()
    records = []
    for cell in cells:
        name = cell['name']
        rect = content_rect(original, cell['rect'])
        # detect_cells includes outer horizontal white borders in first/last rows.
        # Exclude those borders from the transform so they stay fixed gutters.
        patch = corrected.crop(tuple(rect))
        scale = 1.0 if name == 'torso_and_pelvis' else factor
        width, height = patch.size
        # Scale about the cell center. Transform the artwork and its markers
        # together, with no repacking, independent axis fits or cropping.
        cx, cy = width/2, height/2
        if scale != 1:
            patch = flat_cell_background(patch)
            patch = patch.transform(patch.size, Image.Transform.AFFINE,
                                    (1/scale, 0, cx*(1-1/scale),
                                     0, 1/scale, cy*(1-1/scale)),
                                    resample=Image.Resampling.NEAREST,
                                    fillcolor=(255, 0, 255))
            resized.paste(patch, tuple(rect[:2]))
        before_bbox = artwork_bounds(corrected.crop(tuple(rect)))
        after_bbox = artwork_bounds(patch)
        for axis in (0, 1):
            before_size = before_bbox[axis+2]-before_bbox[axis]
            after_size = after_bbox[axis+2]-after_bbox[axis]
            assert abs(after_size - before_size*scale) <= 2, (name, before_bbox, after_bbox)
        center = [rect[0]+cx-.5, rect[1]+cy-.5]
        records.append({'part': name, 'cell_rect': cell['rect'],
                        'transform_rect': rect, 'scale_xy': [scale, scale],
                        'center_pixels': center,
                        'before_artwork_bbox_local': before_bbox,
                        'after_artwork_bbox_local': after_bbox,
                        'markers': [{'before': marker['center'],
                                     'expected_after': [round(center[i]+scale*(marker['center'][i]-center[i]), 4) for i in (0, 1)]}
                                    for marker in before_markers[name]]})
    after_markers = markers_by_cell(resized, cells)
    assert detect_cells(resized) == cells, 'Cell layout changed after resizing'
    for record in records:
        for marker, detected in zip(record['markers'], after_markers[record['part']]):
            marker['detected_after'] = detected['center']
            assert max(abs(marker['expected_after'][i]-detected['center'][i]) for i in (0, 1)) <= 1.1
    torso_rect = tuple(cells[1]['rect'])
    assert np.array_equal(np.asarray(original.crop(torso_rect)), np.asarray(resized.crop(torso_rect)))
    # White gutters, including outer borders, must not change.
    cell_mask = np.zeros((1536, 1024), dtype=bool)
    for record in records:
        x0, y0, x1, y1 = record['transform_rect']
        cell_mask[y0:y1, x0:x1] = True
    assert np.array_equal(np.asarray(original)[~cell_mask], np.asarray(resized)[~cell_mask])
    output_dir.mkdir(parents=True, exist_ok=True)
    corrected_path = output_dir/'oculon_template_boot_split.png'
    final_path = output_dir/'oculon_template_boot_split_78.png'
    corrected.save(corrected_path)
    resized.save(final_path)
    record_path = output_dir/'oculon_template_boot_split_78.json'
    metadata = {'canvas': [1024, 1536], 'original': str(original_path.resolve()),
                'generated_edit': str(generated_path.resolve()),
                'boot_corrected': str(corrected_path.resolve()),
                'final': str(final_path.resolve()), 'non_torso_scale': factor,
                'torso_pixels_unchanged': True, 'gutters_unchanged': True,
                'marker_count': sum(len(v) for v in after_markers.values()),
                'resampling': 'Pillow nearest-neighbor uniform affine, exact factor',
                'final_sha256': hashlib.sha256(final_path.read_bytes()).hexdigest(),
                'parts': records}
    record_path.write_text(json.dumps(metadata, indent=2)+'\n')
    print(json.dumps({k: metadata[k] for k in ('final', 'non_torso_scale', 'marker_count', 'torso_pixels_unchanged', 'gutters_unchanged')}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--original', required=True, type=Path)
    parser.add_argument('--generated', required=True, type=Path)
    parser.add_argument('--output-dir', required=True, type=Path)
    parser.add_argument('--factor', type=float, default=.78)
    args = parser.parse_args()
    run(args.original, args.generated, args.output_dir, args.factor)
