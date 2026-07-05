import SwiftUI

/// Searchable picker over the AutoEq project's published headphone
/// correction database (fetched on demand from GitHub; results are the
/// oratory1990-measured parametric profiles where available).
struct AutoEQPickerView: View {
    var onApply: (String, AutoEQResult) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var entries: [Entry] = []
    @State private var status: String?
    @State private var loadingEntry: String?

    struct Entry: Identifiable {
        let name: String
        let path: String   // repo-relative results/… directory
        var id: String { path }
    }

    private var filtered: [Entry] {
        guard !query.isEmpty else { return Array(entries.prefix(50)) }
        let terms = query.lowercased().split(separator: " ")
        return entries.filter { e in
            let n = e.name.lowercased()
            return terms.allSatisfy { n.contains($0) }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Text("AutoEQ Headphone Database").font(.headline)
            TextField("Search headphones…", text: $query)
                .textFieldStyle(.roundedBorder)
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            List(filtered) { entry in
                HStack {
                    Text(entry.name).font(.caption)
                    Spacer()
                    if loadingEntry == entry.path {
                        ProgressView().controlSize(.small)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { apply(entry) }
            }
            .listStyle(.plain)
            .frame(height: 260)
            Button("Cancel") { dismiss() }
        }
        .padding()
        .frame(width: 360)
        .task { await loadIndex() }
    }

    private func loadIndex() async {
        status = "Loading database index…"
        // The AutoEq results index lists every profile as a markdown link:
        //   - [Name](./<source>/<rig>/<Name>)
        let url = URL(string:
            "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/INDEX.md")!
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let text = String(data: data, encoding: .utf8) else { return }
            var seen = Set<String>()
            var found: [Entry] = []
            for line in text.components(separatedBy: .newlines) {
                guard let open = line.range(of: "["), let close = line.range(of: "]("),
                      let end = line.range(of: ")", range: close.upperBound..<line.endIndex)
                else { continue }
                let name = String(line[open.upperBound..<close.lowerBound])
                var path = String(line[close.upperBound..<end.lowerBound])
                if path.hasPrefix("./") { path.removeFirst(2) }
                guard !name.isEmpty, !path.isEmpty, !seen.contains(name) else { continue }
                seen.insert(name)
                found.append(Entry(name: name, path: path))
            }
            entries = found
            status = "\(found.count) headphones"
        } catch {
            status = "Could not load index: \(error.localizedDescription)"
        }
    }

    private func apply(_ entry: Entry) {
        loadingEntry = entry.path
        status = nil
        Task {
            defer { loadingEntry = nil }
            let encoded = entry.path.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed) ?? entry.path
            let nameEncoded = entry.name.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed) ?? entry.name
            let url = URL(string:
                "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/"
                + "\(encoded)/\(nameEncoded)%20ParametricEQ.txt")!
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let text = String(data: data, encoding: .utf8) else {
                    status = "No parametric profile for this entry"
                    return
                }
                let parsed = AutoEQParser.parse(text)
                guard !parsed.bands.isEmpty else {
                    status = "Profile could not be parsed"
                    return
                }
                onApply(entry.name, parsed)
                dismiss()
            } catch {
                status = "Download failed: \(error.localizedDescription)"
            }
        }
    }
}
