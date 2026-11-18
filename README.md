# EPUB Edit

A native document editor for macOS 26 or later. Right-click an EPUB in Finder and choose **Edit**. The editor also accepts files through **File → Open** or by dropping them on its welcome window.

## Use

1. Open **EPUB Edit** once so macOS registers its EPUB service.
2. Right-click a book in Finder and choose **Edit**. Finder can group this command under **Services** when several services apply. The command also works when EPUB Edit is closed.
3. Change the title, primary author, language, publisher, description, or cover. **Formatting** changes the font family and line spacing in reflowable XHTML chapters. **Book default** restores the publisher’s formatting.
4. Press **⌘S** to save changes to the current EPUB. Use **File → Save As…** to keep a separate copy.

## Fix for Kindle

Open a reflowable EPUB and click **Fix for Kindle**. When a repair applies, the editor writes **Book (Kindle).epub** beside the source and offers **Show in Finder**. This copy includes the edits visible in the editor. Existing copies keep their names, and successive exports receive a number. If the checks find nothing to change, the editor reports that result without writing a file.

The repair checks fixed-size text styles, repeated chapter stylesheets, and the EPUB’s ZIP header. Its report counts the changes it made. You can send the resulting EPUB to your e-reader using Send to Kindle.

Kindle indexes books after delivery, which can use extra battery. An EPUB repair can address formatting issues. Measuring battery drain requires a comparison on the device after indexing. [Kindle text guidelines](https://kdp.amazon.com/en_US/help/topic/GH4DRT75GWWAGBTU) · [Kindle battery guidance](https://digprjsurvey.amazon.com/csad/help/node/G4GMVBJTKV5K77V6)

The editor handles single-package EPUB 2 and EPUB 3 files up to 512 MiB. Covers can be imported from JPEG or PNG. Signed books and books with an encryption manifest, including obfuscated fonts, are unsupported. Fixed-layout books allow changes to book details and supported covers. Reading apps may apply their own typography.

## Build

With the macOS 26 SDK and Xcode command-line tools installed, run:

```sh
swift test
./scripts/build-app.sh
```

Copy `build/EPUB Edit.app` into Applications and open it once. The script builds for the current Mac’s architecture and signs the app locally. A signing identity can be supplied through `CODE_SIGN_IDENTITY`.
