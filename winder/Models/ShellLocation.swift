import Foundation

/// Windows 탐색기 가상 위치 → macOS 파일시스템 경로 매핑
enum ShellLocation: Hashable {
    case home
    case cloudDrive
    case knownFolder(KnownFolder)
    case volume(URL)                 // 마운트된 볼륨
    case network
    case trash
    case path(URL)

    /// macOS 실제 URL (탐색 불가 위치는 nil)
    var url: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .home:                    return home
        case .cloudDrive:              return home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        case .knownFolder(let f):      return f.url
        case .volume(let url):         return url
        case .network:                 return nil
        case .trash:                   return home.appendingPathComponent(".Trash")
        case .path(let url):           return url
        }
    }

    var displayName: String {
        switch self {
        case .home:                        return "홈"
        case .cloudDrive:                  return "iCloud Drive"
        case .knownFolder(let f):          return f.displayName
        case .volume(let url):             return FileManager.default.displayName(atPath: url.path)
        case .network:                     return "네트워크"
        case .trash:                       return "휴지통"
        case .path(let url):               return FileManager.default.displayName(atPath: url.path)
        }
    }

    var systemIcon: String {
        switch self {
        case .home:              return FluentIcons.home
        case .cloudDrive:        return FluentIcons.cloud
        case .knownFolder(let f): return f.systemIcon
        case .volume:            return FluentIcons.drive
        case .network:           return FluentIcons.network
        case .trash:             return FluentIcons.trash
        case .path:              return FluentIcons.folder
        }
    }
}

/// Windows 탐색기의 알려진 폴더 → macOS 홈 디렉토리 매핑
/// 트리에 고정 나열하지 않고 즐겨찾기 기본값 시드·아이콘 매핑에 사용한다
enum KnownFolder: String, Hashable, CaseIterable {
    case desktop, documents, downloads, music, pictures, movies

    var url: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .desktop:   return home.appendingPathComponent("Desktop")
        case .documents: return home.appendingPathComponent("Documents")
        case .downloads: return home.appendingPathComponent("Downloads")
        case .music:     return home.appendingPathComponent("Music")
        case .pictures:  return home.appendingPathComponent("Pictures")
        case .movies:    return home.appendingPathComponent("Movies")
        }
    }

    var displayName: String {
        switch self {
        case .desktop:   return "바탕 화면"
        case .documents: return "문서"
        case .downloads: return "다운로드"
        case .music:     return "음악"
        case .pictures:  return "사진"
        case .movies:    return "비디오"
        }
    }

    var systemIcon: String {
        switch self {
        case .desktop:   return FluentIcons.desktop
        case .documents: return FluentIcons.documents
        case .downloads: return FluentIcons.downloads
        case .music:     return FluentIcons.music
        case .pictures:  return FluentIcons.pictures
        case .movies:    return FluentIcons.videos
        }
    }
}
