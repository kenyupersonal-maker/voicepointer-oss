import Foundation

public enum IntegratedRuntimePaths {
    public static var dataRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.kenyu.voicepointer.mac")
    }

    public static var backendResources: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Backend")
    }

    public static var modelsRoot: URL { dataRoot.appendingPathComponent("Models", isDirectory: true) }

    public static var assetRoot: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Seed/payload", isDirectory: true)
    }
}
