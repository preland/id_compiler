#!/usr/bin/env python3
"""Generate tests/fixtures/sample.odt -- a minimal but real OpenDocument text.

A fixture rather than a checked-in binary: an .odt is a ZIP, and a ZIP written
by hand would be a ZIP nobody else writes. This one goes through zipfile, so
what the reader is tested against is the format as a library produces it --
deflated entries, a central directory, and the uncompressed `mimetype` entry
first that the specification requires.
"""
import zipfile, sys, os

CONTENT = '''<?xml version="1.0" encoding="UTF-8"?>
<office:document-content
 xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
 xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
 xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
 xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"
 office:version="1.3">
 <office:automatic-styles>
  <style:style style:name="T1" style:family="text">
   <style:text-properties style:font-name="DejaVu Sans" fo:font-size="12pt"/>
  </style:style>
  <style:style style:name="T2" style:family="text">
   <style:text-properties style:font-name="DejaVu Sans" fo:font-size="12pt"
    fo:font-weight="bold"/>
  </style:style>
  <style:style style:name="T3" style:family="text">
   <style:text-properties style:font-name="DejaVu Serif" fo:font-size="18pt"
    fo:font-style="italic"/>
  </style:style>
 </office:automatic-styles>
 <office:body>
  <office:text>
   <text:p text:style-name="P1"><text:span text:style-name="T3">A document, read by id</text:span></text:p>
   <text:p text:style-name="P1"><text:span text:style-name="T1">This paragraph is plain text at twelve points. It is long enough that a
   renderer has to break it into lines rather than trusting it to fit, which is
   the point of it being here.</text:span></text:p>
   <text:p text:style-name="P1"><text:span text:style-name="T1">Styles change mid-paragraph: </text:span><text:span text:style-name="T2">this run is bold</text:span><text:span text:style-name="T1"> and this one is not. Entities survive too &amp; so do &lt;angle brackets&gt;.</text:span></text:p>
   <text:p text:style-name="P1"/>
   <text:p text:style-name="P1"><text:span text:style-name="T1">Numbers 0123456789 and punctuation .,;:!?()-- render from the same font.</text:span></text:p>
  </office:text>
 </office:body>
</office:document-content>
'''

STYLES = '''<?xml version="1.0" encoding="UTF-8"?>
<office:document-styles
 xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
 xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
 xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"
 office:version="1.3">
 <office:styles>
  <style:default-style style:family="paragraph">
   <style:text-properties style:font-name="DejaVu Sans" fo:font-size="12pt"/>
  </style:default-style>
 </office:styles>
</office:document-styles>
'''

MANIFEST = '''<?xml version="1.0" encoding="UTF-8"?>
<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3">
 <manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.text"/>
 <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
 <manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/>
</manifest:manifest>
'''

def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "tests/fixtures/sample.odt"
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with zipfile.ZipFile(out, "w") as z:
        # The mimetype entry is first and stored, not deflated -- that is what
        # lets a reader identify the format from the first bytes of the file.
        z.writestr(zipfile.ZipInfo("mimetype"),
                   "application/vnd.oasis.opendocument.text",
                   compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/manifest.xml", MANIFEST, zipfile.ZIP_DEFLATED)
        z.writestr("styles.xml", STYLES, zipfile.ZIP_DEFLATED)
        z.writestr("content.xml", CONTENT, zipfile.ZIP_DEFLATED)
    print(f"wrote {out} ({os.path.getsize(out)} bytes)")

main()
