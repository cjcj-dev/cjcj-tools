package cjcompat

main(args: Array<String>): Int64 {
    try {
        let opts = ParseOptions(args)
        if (opts.end) { return 0 }
        let before = Library(opts.oldPath, opts.paths)
        let after = Library(opts.newPath, opts.paths)
        let result = Comparison(before, after, opts)
        result.Run()
        result.Print()
        // The established CLI uses exit 0 for a completed comparison, including
        // incompatibility; malformed arguments and unreadable CJO use exit 1.
        return 0
    } catch (error: Exception) {
        eprintln("Error: " + error.message)
        return 1
    }
}
