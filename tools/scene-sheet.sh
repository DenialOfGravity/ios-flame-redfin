#!/bin/bash
# Contact sheet of tools/flame-scenes.sh shots, in tour order: scene-sheet.sh DIR [OUT.png] [COLS]
dir=$1; out=${2:-$dir/sheet.png}; cols=${3:-7}
order="lock home settings general control notifications today spotlight clock calendar notes photos safari"
tmp=$(mktemp -d); i=0
for s in $order; do [ -f "$dir/$s.png" ] && { ln -s "$PWD/$dir/$s.png" "$tmp/$(printf %02d $i).png"; i=$((i + 1)); }; done
rows=$(( (i + cols - 1) / cols ))
ffmpeg -v error -y -framerate 1 -i "$tmp/%02d.png" -vf "scale=216:-1,tile=${cols}x${rows}:padding=4:color=gray" -frames:v 1 "$out"
rm -rf "$tmp"; echo "$out ($i shots)"
