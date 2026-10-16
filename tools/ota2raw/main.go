// ota2raw turns a pepito LineageOS OTA zip into the raw partition images that
// qdl writes over EDL (Qualcomm 9008).
//
// The OTA zip carries system and vendor as brotli-compressed block streams
// (<part>.new.dat.br + <part>.transfer.list) and boot/recovery as unpadded
// images. qdl wants plain partition images, so this rebuilds them:
//
//	boot.bin, recovery.bin   boot.img / recovery.img, zero-padded
//	system.bin, vendor.bin   the block stream written out per the transfer list
//	config.bin               zero-fill (clears a stale FRP token)
//	splash.bin               firmware-update/splash.img: the boot logo, the
//	                         first 128 KiB of the splash partition
//
// What to build, and the SHA-256 every result must have, comes from
// edl/manifest.json inside the zip (written by scripts/release.sh, which checks
// at release time that these images are byte-identical to the ones the build
// itself staged). Everything else in the zip's edl/ folder (firehose loaders,
// rawprogram XMLs, qdl, README) is copied next to the images, so the output
// folder is a complete flashing kit.
//
// Usage:
//
//	ota2raw                     run from the edl/ folder of an extracted zip
//	ota2raw lineage-....zip     read the zip directly, write ./<zip name>-edl/
//	ota2raw extracted-folder    same as the first form, from anywhere
//	  -o DIR                    write the images to DIR instead
package main

import (
	"archive/zip"
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"github.com/andybalholm/brotli"
)

// Set at build time (tools/ota2raw/build.sh).
var version = "dev"

// Progress percentages are only drawn on a terminal, not into a log.
var interactive = func() bool {
	st, err := os.Stdout.Stat()
	return err == nil && st.Mode()&os.ModeCharDevice != 0
}()

const (
	flasherURL   = "https://solarkennedy.github.io/lineageos-pepito/flasher/"
	blockSize    = 4096
	manifestPath = "edl/manifest.json"
	kitDir       = "edl"
)

type image struct {
	Name   string `json:"name"`   // output file name, e.g. system.bin
	Type   string `json:"type"`   // "file", "blocks" or "zero"
	Source string `json:"source"` // file: entry name; blocks: partition name
	Size   int64  `json:"size"`   // file: pad to this size; zero: length
	SHA256 string `json:"sha256"` // of the finished image
}

type manifest struct {
	Version int     `json:"version"`
	Build   string  `json:"build"`
	Images  []image `json:"images"`
}

func main() {
	err := run()
	if err != nil {
		fmt.Fprintln(os.Stderr, "\nERROR:", err)
	}
	// Double-clicked on Windows: keep the console open long enough to read.
	if runtime.GOOS == "windows" && len(os.Args) == 1 {
		fmt.Print("\nPress Enter to close this window.")
		bufio.NewReader(os.Stdin).ReadString('\n')
	}
	if err != nil {
		os.Exit(1)
	}
}

func run() error {
	outFlag := flag.String("o", "", "write the images to `DIR`")
	showVersion := flag.Bool("version", false, "print the version and exit")
	flag.Usage = func() {
		fmt.Fprintf(flag.CommandLine.Output(),
			"ota2raw %s: convert a pepito LineageOS OTA zip into raw images for qdl\n\n"+
				"usage: %s [-o DIR] [OTA.zip | extracted-folder]\n\n"+
				"With no argument, run it from the edl/ folder of an extracted zip.\n",
			version, filepath.Base(os.Args[0]))
		flag.PrintDefaults()
	}
	flag.Parse()
	if *showVersion {
		fmt.Println("ota2raw", version)
		return nil
	}
	if flag.NArg() > 1 {
		flag.Usage()
		return errors.New("expected at most one input")
	}

	src, outDir, fromZip, closeSrc, err := openInput(flag.Arg(0))
	if err != nil {
		return err
	}
	defer closeSrc()
	if *outFlag != "" {
		outDir = *outFlag
	}

	raw, err := fs.ReadFile(src, manifestPath)
	if err != nil {
		return fmt.Errorf("no %s in the input: this is not a pepito release zip with the EDL kit (%w)", manifestPath, err)
	}
	var m manifest
	if err := json.Unmarshal(raw, &m); err != nil {
		return fmt.Errorf("%s: %w", manifestPath, err)
	}
	if m.Version != 1 {
		return fmt.Errorf("%s is format version %d; this ota2raw only knows version 1, use the one shipped in that zip", manifestPath, m.Version)
	}

	outDir = absPath(outDir)
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return err
	}
	fmt.Printf("ota2raw %s\nBuild:  %s\nOutput: %s\n\n", version, m.Build, outDir)

	if fromZip {
		if err := copyKit(src, outDir); err != nil {
			return err
		}
	}
	for _, img := range m.Images {
		if img.Name != filepath.Base(img.Name) || img.Name == "" {
			return fmt.Errorf("manifest: bad image name %q", img.Name)
		}
		dst := filepath.Join(outDir, img.Name)
		if interactive {
			fmt.Printf("%-14s ", img.Name)
		}
		var err error
		switch img.Type {
		case "file":
			err = buildFile(src, img, dst)
		case "blocks":
			err = buildBlocks(src, img, dst)
		case "zero":
			err = buildZero(img, dst)
		default:
			err = fmt.Errorf("unknown image type %q", img.Type)
		}
		if err != nil {
			return fmt.Errorf("%s: %w", img.Name, err)
		}
		sum, size, err := hashFile(dst)
		if err != nil {
			return err
		}
		if !strings.EqualFold(sum, img.SHA256) {
			return fmt.Errorf("%s: CHECKSUM MISMATCH: sha256 is %s, expected %s. Do not flash it: the download is probably corrupt, fetch the zip again", img.Name, sum, img.SHA256)
		}
		if interactive {
			fmt.Print("\r")
		}
		if size < 1<<20 {
			fmt.Printf("%-14s %6d KiB  verified\n", img.Name, size>>10)
		} else {
			fmt.Printf("%-14s %6d MiB  verified\n", img.Name, size>>20)
		}
	}

	if runtime.GOOS != "windows" {
		// Zip signing drops the Unix mode bits, so restore them on the tools.
		for _, tool := range []string{"qdl", "qdl-dump.sh"} {
			if p := filepath.Join(outDir, tool); fileExists(p) {
				os.Chmod(p, 0o755)
			}
		}
	}

	fmt.Printf("\nDone. The images are in %s, next to the loaders and partition XMLs.\n"+
		"Next: flash from your browser at %s\n"+
		"(choose this folder when it asks for the images), or follow the qdl steps in the README.\n", outDir, flasherURL)
	return nil
}

// openInput resolves the input (a zip, an extracted folder, or nothing) to a
// filesystem rooted at the zip's top level, and picks the default output dir.
func openInput(arg string) (src fs.FS, outDir string, fromZip bool, closer func(), err error) {
	closer = func() {}
	if arg == "" {
		// No argument: we are <extracted>/edl/ota2raw-<os>, or in that folder.
		candidates := []string{"."}
		if exe, e := os.Executable(); e == nil {
			candidates = append([]string{filepath.Dir(exe)}, candidates...)
		}
		for _, edl := range candidates {
			root := filepath.Dir(absPath(edl))
			if fileExists(filepath.Join(root, filepath.FromSlash(manifestPath))) {
				return os.DirFS(root), filepath.Join(root, kitDir), false, closer, nil
			}
		}
		return nil, "", false, closer, errors.New("no input given and this program is not inside an extracted release zip.\n" +
			"Run it from the zip's edl/ folder, or pass the zip: ota2raw lineage-....zip")
	}
	st, e := os.Stat(arg)
	if e != nil {
		return nil, "", false, closer, e
	}
	if st.IsDir() {
		return os.DirFS(arg), filepath.Join(arg, kitDir), false, closer, nil
	}
	zr, e := zip.OpenReader(arg)
	if e != nil {
		return nil, "", false, closer, fmt.Errorf("%s: %w", arg, e)
	}
	name := strings.TrimSuffix(filepath.Base(arg), filepath.Ext(arg)) + "-edl"
	return zr, name, true, func() { zr.Close() }, nil
}

// copyKit extracts the zip's edl/ folder (loaders, XMLs, tools, README) into
// outDir, so the result is self-contained.
func copyKit(src fs.FS, outDir string) error {
	entries, err := fs.ReadDir(src, kitDir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		dst := filepath.Join(outDir, e.Name())
		// Extracting into the kit folder itself (-o .): what is already there,
		// this running program included, stays as it is.
		if info, err := e.Info(); err == nil {
			if st, err := os.Stat(dst); err == nil && st.Size() == info.Size() {
				continue
			}
		}
		in, err := src.Open(path.Join(kitDir, e.Name()))
		if err != nil {
			return err
		}
		err = writeFrom(dst, in, -1)
		in.Close()
		if err != nil {
			return err
		}
	}
	// The README sits at the zip's top level.
	if in, err := src.Open("README.md"); err == nil {
		defer in.Close()
		return writeFrom(filepath.Join(outDir, "README.md"), in, -1)
	}
	return nil
}

// buildFile copies one zip entry and zero-pads it to img.Size.
func buildFile(src fs.FS, img image, dst string) error {
	in, err := src.Open(img.Source)
	if err != nil {
		return err
	}
	defer in.Close()
	return writeFrom(dst, in, img.Size)
}

func buildZero(img image, dst string) error {
	return writeFrom(dst, strings.NewReader(""), img.Size)
}

// writeFrom writes r to dst. With padTo >= 0 the file is extended with zeros to
// exactly that size, and it is an error for the data to be longer.
func writeFrom(dst string, r io.Reader, padTo int64) error {
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	n, err := io.Copy(out, r)
	if err == nil && padTo >= 0 {
		if n > padTo {
			err = fmt.Errorf("source is %d bytes, larger than the %d-byte image", n, padTo)
		} else {
			err = out.Truncate(padTo)
		}
	}
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	return err
}

type blockRange struct{ start, end int64 } // blocks, end exclusive

type command struct {
	op     string
	ranges []blockRange
}

// parseTransferList reads a block-OTA transfer list (versions 1-4). Only the
// commands a FULL OTA uses are accepted: an incremental OTA patches blocks
// already on the phone and cannot be turned into an image.
func parseTransferList(data []byte) ([]command, error) {
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) < 2 {
		return nil, errors.New("transfer list is too short")
	}
	ver, err := strconv.Atoi(strings.TrimSpace(lines[0]))
	if err != nil || ver < 1 || ver > 4 {
		return nil, fmt.Errorf("unsupported transfer list version %q", lines[0])
	}
	// Line 2 is the block count; versions 2+ add two stash lines.
	body := lines[2:]
	if ver >= 2 {
		if len(lines) < 4 {
			return nil, errors.New("transfer list is too short")
		}
		body = lines[4:]
	}
	var cmds []command
	for _, line := range body {
		f := strings.Fields(line)
		if len(f) == 0 {
			continue
		}
		switch f[0] {
		case "new", "zero", "erase":
			if len(f) != 2 {
				return nil, fmt.Errorf("malformed command %q", line)
			}
			r, err := parseRanges(f[1])
			if err != nil {
				return nil, fmt.Errorf("%q: %w", line, err)
			}
			cmds = append(cmds, command{f[0], r})
		default:
			return nil, fmt.Errorf("command %q needs the blocks already on the phone: this is an incremental OTA, only full OTA zips can be converted", f[0])
		}
	}
	return cmds, nil
}

// parseRanges parses "N,a,b,c,d,...": N numbers follow, as [start,end) pairs.
func parseRanges(s string) ([]blockRange, error) {
	parts := strings.Split(s, ",")
	n, err := strconv.Atoi(parts[0])
	if err != nil || n != len(parts)-1 || n%2 != 0 || n == 0 {
		return nil, fmt.Errorf("bad block range %q", s)
	}
	out := make([]blockRange, 0, n/2)
	for i := 1; i < len(parts); i += 2 {
		a, err1 := strconv.ParseInt(parts[i], 10, 64)
		b, err2 := strconv.ParseInt(parts[i+1], 10, 64)
		if err1 != nil || err2 != nil || a < 0 || b <= a {
			return nil, fmt.Errorf("bad block range %q", s)
		}
		out = append(out, blockRange{a, b})
	}
	return out, nil
}

// buildBlocks writes <part>.new.dat.br out as a raw image per
// <part>.transfer.list. "new" ranges take the next blocks of the decompressed
// stream; "zero" and "erase" ranges are left as zeros, which is what the
// build's own sparse-to-raw conversion produces for them.
func buildBlocks(src fs.FS, img image, dst string) error {
	list, err := fs.ReadFile(src, img.Source+".transfer.list")
	if err != nil {
		return err
	}
	cmds, err := parseTransferList(list)
	if err != nil {
		return fmt.Errorf("%s.transfer.list: %w", img.Source, err)
	}
	var total, newBlocks int64
	for _, c := range cmds {
		for _, r := range c.ranges {
			if r.end > total {
				total = r.end
			}
			if c.op == "new" {
				newBlocks += r.end - r.start
			}
		}
	}

	in, err := src.Open(img.Source + ".new.dat.br")
	if err != nil {
		return err
	}
	defer in.Close()
	data := brotli.NewReader(bufio.NewReaderSize(in, 1<<20))

	out, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer out.Close()
	if err := out.Truncate(total * blockSize); err != nil {
		return err
	}

	buf := make([]byte, 4<<20)
	var done int64
	lastPct := int64(-1)
	for _, c := range cmds {
		if c.op != "new" {
			continue
		}
		for _, r := range c.ranges {
			off := r.start * blockSize
			left := (r.end - r.start) * blockSize
			for left > 0 {
				chunk := buf
				if int64(len(chunk)) > left {
					chunk = chunk[:left]
				}
				if _, err := io.ReadFull(data, chunk); err != nil {
					return fmt.Errorf("%s.new.dat.br: %w (truncated or corrupt download?)", img.Source, err)
				}
				if _, err := out.WriteAt(chunk, off); err != nil {
					return err
				}
				off += int64(len(chunk))
				left -= int64(len(chunk))
				done += int64(len(chunk))
				if pct := done * 100 / (newBlocks * blockSize); pct != lastPct && interactive {
					lastPct = pct
					fmt.Printf("\r%-14s %3d%%", img.Name, pct)
				}
			}
		}
	}
	if n, _ := data.Read(buf[:1]); n != 0 {
		return fmt.Errorf("%s.new.dat.br holds more data than the transfer list uses", img.Source)
	}
	return out.Close()
}

func hashFile(p string) (string, int64, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	h := sha256.New()
	n, err := io.CopyBuffer(h, f, make([]byte, 4<<20))
	if err != nil {
		return "", 0, err
	}
	return hex.EncodeToString(h.Sum(nil)), n, nil
}

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

func absPath(p string) string {
	if a, err := filepath.Abs(p); err == nil {
		return a
	}
	return p
}
