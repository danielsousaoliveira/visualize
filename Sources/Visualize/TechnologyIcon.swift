import AppKit
import SwiftUI

struct TechnologyIcon: View {
    let technology: String?
    var size: CGFloat = 18

    private static let aliases = [
        "nextjs": "nextdotjs", "vue": "vuedotjs", "node": "nodedotjs",
        "nestjs": "nestjs", "rails": "rubyonrails", "postgres": "postgresql",
        "spring-boot": "spring", "springboot": "spring", "blazor": "dotnet",
        "sveltekit": "svelte", "cra": "react", "vite": "vite",
        "gin": "go", "fiber": "go", "echo": "go",
        "actix": "rust", "axum": "rust", "rocket": "rust",
        "java": "openjdk", "cplusplus": "cplusplus", "cpp": "cplusplus",
        "csharp": "dotnet", "phoenix": "phoenixframework", "adonis": "adonisjs",
        "static": "html5", "sinatra": "ruby", "koa": "nodedotjs", "elysia": "bun",
        "aspnet": "dotnet", "nuxtjs": "nuxt", "react-native": "react"
    ]
    private static let images: [String: NSImage] = {
        guard let directory = Bundle.module.url(forResource: "Icons", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [:] }
        return Dictionary(uniqueKeysWithValues: files.filter { $0.pathExtension == "pdf" }.compactMap { url in
            guard let image = NSImage(contentsOf: url) else { return nil }
            image.isTemplate = true
            return (url.deletingPathExtension().lastPathComponent, image)
        })
    }()
    private var image: Image {
        let key = technology?.lowercased() ?? ""
        if let image = Self.images[Self.aliases[key] ?? key] { return Image(nsImage: image) }
        let symbol = NSImage(systemSymbolName: "circle.hexagongrid", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .light))
        return symbol.map { Image(nsImage: $0) } ?? Image(systemName: "circle.hexagongrid")
    }

    var body: some View {
        image
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(Color(nsColor: .labelColor).opacity(0.85))
            .accessibilityHidden(true)
    }
}
