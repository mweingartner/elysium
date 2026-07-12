import Darwin

func readRelative(_ parent: Int32, _ name: String) -> Int32 {
    openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
}

// sqlite3_open and SELECT FROM are comments and must not become capabilities.
