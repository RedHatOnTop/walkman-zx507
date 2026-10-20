# kit/

What `scripts/make-install.sh` checks its inputs against, and the commit a copy of this
repository was taken at.

- `stock-<firmware>-<series>.sha256`: the four partitions the build takes from Sony's UPG, as
  `scripts/unpack-stock.sh` extracts them. Only hashes; the images come from the owner's own
  firmware file.
- `COMMIT`: `git archive` writes the commit into it (`.gitattributes`, `export-subst`), so a
  copy made that way says what it was made from without a `.git`. In a checkout it reads
  `$Format:%H$` and the scripts ask git instead.
