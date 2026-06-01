import CoreLocation
import Foundation

enum ContextBuilder {
  struct Output {
    let text: String
    /// Equal signatures mean the configured context sources haven't changed.
    let signature: String
  }

  @MainActor
  static func build(
    input: String,
    conversation: Conversation,
    settings: AppSettings,
    locationService: @MainActor () -> LocationService
  ) async -> Output {
    var sections: [String] = []
    var signatureParts: [String] = []
    guard conversation.toolsEnabled else {
      return Output(text: "", signature: "")
    }
    let enabled = conversation.enabledTools

    if enabled.contains(.datetime) {
      sections.append(DateTimeRenderer.render(settings: settings.toolSettings))
      signatureParts.append(
        "datetime:\(DateTimeRenderer.signature(settings: settings.toolSettings))")
    }
    if enabled.contains(.language) {
      sections.append(
        LanguagePreferenceRenderer.render(conversation: conversation, settings: settings))
      signatureParts.append(
        "language:\(LanguagePreferenceRenderer.signature(conversation: conversation, settings: settings))"
      )
    }
    if enabled.contains(.location) {
      sections.append(
        await LocationRenderer.render(
          settings: settings.toolSettings, locationService: locationService))
      signatureParts.append(
        "location:\(LocationRenderer.signature(settings: settings.toolSettings))")
    }
    if enabled.contains(.files) {
      let files = filesContext(settings: settings.toolSettings)
      if !files.isEmpty {
        sections.append(files)
        signatureParts.append("files:\(filesSignature(settings: settings.toolSettings))")
      }
    }
    return Output(
      text: sections.joined(separator: "\n\n"),
      signature: signatureParts.joined(separator: "|"))
  }

  private static func filesContext(settings: NativeToolSettings) -> String {
    let files = settings.files.map { file in
      """
      File: \(file.name)
      \(file.excerpt)
      """
    }
    return files.isEmpty ? "" : "Files tool:\n" + files.joined(separator: "\n\n")
  }

  private static func filesSignature(settings: NativeToolSettings) -> String {
    settings.files.map { "\($0.id.uuidString)\($0.name)\($0.excerpt.count)" }
      .joined(separator: ",")
  }
}

enum LanguagePreferenceRenderer {
  static func render(conversation: Conversation, settings: AppSettings) -> String {
    let label = languageLabel(conversation: conversation, settings: settings)
    return "Language Preference tool:\nUser prefers \(label) language."
  }

  static func signature(conversation: Conversation, settings: AppSettings) -> String {
    languageIdentifier(conversation: conversation, settings: settings) ?? ""
  }

  private static func languageLabel(conversation: Conversation, settings: AppSettings) -> String {
    guard let identifier = languageIdentifier(conversation: conversation, settings: settings) else {
      return SystemLanguageSupport.languageDisplayName(Locale.current.identifier)
    }
    return SystemLanguageSupport.languageDisplayName(identifier)
  }

  private static func languageIdentifier(conversation: Conversation, settings: AppSettings)
    -> String?
  {
    if let override = conversation.effectiveLanguageOverrideIdentifier {
      return override
    }

    let candidates = [
      settings.conversation.speechRecognitionLanguageIdentifier,
      settings.toolSettings.voices.user.language,
      settings.toolSettings.voices.assistant.language,
      Locale.current.identifier,
    ]
    return candidates.lazy.compactMap(SystemLanguageSupport.normalizedLanguageIdentifier).first
  }
}

enum DateTimeRenderer {
  static func render(settings: NativeToolSettings) -> String {
    var values: [String] = []
    let now = Date()
    let formatter = DateFormatter()
    formatter.dateStyle = .full
    formatter.timeStyle = .long
    values.append("Current date/time: \(formatter.string(from: now))")
    if settings.includeTimeZone {
      values.append("Time zone: \(TimeZone.current.identifier)")
    }
    if settings.includeMoonPhase {
      values.append(WeatherService.moonPhaseLine(for: now))
    }
    return "Date & Time tool:\n" + values.joined(separator: "\n")
  }

  static func signature(settings: NativeToolSettings) -> String {
    "\(settings.includeTimeZone ? 1 : 0)\(settings.includeMoonPhase ? 1 : 0)"
  }
}

enum LocationRenderer {
  @MainActor
  static func render(
    settings: NativeToolSettings,
    locationService: @MainActor () -> LocationService
  ) async -> String {
    if settings.useGPSLocation {
      return "Location tool:\n\(await locationService().currentLocationText())"
    }
    let manual = settings.manualLocation.trimmingCharacters(in: .whitespacesAndNewlines)
    return manual.isEmpty ? "Location tool:\nNo location configured" : "Location tool:\n\(manual)"
  }

  static func signature(settings: NativeToolSettings) -> String {
    "\(settings.useGPSLocation ? "gps" : "manual"):\(settings.manualLocation)"
  }
}

enum WeatherService {
  private static let minimumForecastDays = 7

  private struct ProviderReport {
    let body: String
    let forecastDayCount: Int
    let coordinate: CLLocationCoordinate2D?
  }

  @MainActor
  static func report(
    settings: NativeToolSettings,
    locationService: @MainActor () -> LocationService
  ) async -> String? {
    let manual = settings.weatherLocation.trimmingCharacters(in: .whitespacesAndNewlines)
    var coordinate: CLLocationCoordinate2D? = nil
    if manual.isEmpty, settings.useGPSLocation {
      coordinate = await locationService().currentCoordinate()
    }

    let primary = await wttrInReport(manual: manual, coordinate: coordinate)
    if let primary, primary.forecastDayCount >= minimumForecastDays {
      return withMoonPhase(primary.body)
    }

    let secondary = await openMeteoReport(
      manual: manual,
      coordinate: coordinate ?? primary?.coordinate
    )
    if let secondary, secondary.forecastDayCount >= minimumForecastDays {
      return withMoonPhase(secondary.body)
    }
    if let primary, let secondary, secondary.forecastDayCount > primary.forecastDayCount {
      return withMoonPhase(secondary.body)
    }
    if let primary {
      return withMoonPhase(primary.body)
    }
    if let secondary {
      return withMoonPhase(secondary.body)
    }
    return nil
  }

  private static func withMoonPhase(_ body: String) -> String {
    body + "\n\n" + moonPhaseLine(for: Date())
  }

  // MARK: - wttr.in (rich JSON)

  private static func wttrInReport(
    manual: String, coordinate: CLLocationCoordinate2D?
  ) async -> ProviderReport? {
    let path: String
    if !manual.isEmpty {
      let encoded = manual.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
      path = encoded
    } else if let coordinate {
      path = String(format: "%.4f,%.4f", coordinate.latitude, coordinate.longitude)
    } else {
      path = ""
    }
    guard let url = URL(string: "https://wttr.in/\(path)?format=j1") else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 6
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    guard
      let (data, response) = try? await URLSession.shared.data(for: request),
      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return formatWttrIn(object)
  }

  private static func formatWttrIn(_ object: [String: Any]) -> ProviderReport? {
    let area = ((object["nearest_area"] as? [[String: Any]])?.first) ?? [:]
    let areaName = areaDisplayName(area)
    let areaCoordinate = areaCoordinate(area)

    var lines: [String] = []
    if !areaName.isEmpty {
      lines.append("Location: \(areaName)")
    }

    if let current = (object["current_condition"] as? [[String: Any]])?.first {
      let temp = firstString(current["temp_C"]) ?? "?"
      let feels = firstString(current["FeelsLikeC"]) ?? "?"
      let desc = firstDescription(current["weatherDesc"]) ?? ""
      let humidity = firstString(current["humidity"]) ?? "?"
      let wind = firstString(current["windspeedKmph"]) ?? "?"
      let windDir = firstString(current["winddir16Point"]) ?? ""
      let precip = firstString(current["precipMM"]) ?? "0"
      lines.append("Now: \(desc), \(temp)°C (feels \(feels)°C), humidity \(humidity)%")
      lines.append("Wind: \(wind) km/h \(windDir)")
      lines.append("Precipitation: \(precip) mm")
    }

    var forecastDayCount = 0
    if let weather = object["weather"] as? [[String: Any]], !weather.isEmpty {
      lines.append("")
      let forecast = Array(weather.prefix(minimumForecastDays))
      forecastDayCount = forecast.count
      lines.append("Forecast (\(forecastDayCount) days):")
      for day in forecast {
        let date = (day["date"] as? String) ?? ""
        let minT = (day["mintempC"] as? String) ?? "?"
        let maxT = (day["maxtempC"] as? String) ?? "?"
        let mid = (day["hourly"] as? [[String: Any]])?.dropFirst(4).first
        let desc = firstDescription(mid?["weatherDesc"]) ?? ""
        let wind = (mid?["windspeedKmph"] as? String) ?? "?"
        let chanceRain = (mid?["chanceofrain"] as? String) ?? "0"
        lines.append(
          "- \(date): \(minT)–\(maxT)°C, \(desc); wind \(wind) km/h; rain \(chanceRain)%")
      }
    }

    let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return body.isEmpty
      ? nil
      : ProviderReport(
        body: body,
        forecastDayCount: forecastDayCount,
        coordinate: areaCoordinate
      )
  }

  private static func areaDisplayName(_ area: [String: Any]) -> String {
    let name = firstString(area["areaName"]) ?? ""
    let country = firstString(area["country"]) ?? ""
    let region = firstString(area["region"]) ?? ""
    let parts = [name, region, country].filter { !$0.isEmpty }
    return parts.joined(separator: ", ")
  }

  private static func areaCoordinate(_ area: [String: Any]) -> CLLocationCoordinate2D? {
    guard
      let latitude = firstDouble(area["latitude"]),
      let longitude = firstDouble(area["longitude"])
    else {
      return nil
    }
    return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }

  private static func firstString(_ raw: Any?) -> String? {
    if let s = raw as? String, !s.isEmpty { return s }
    if let array = raw as? [[String: Any]],
      let value = array.first?["value"] as? String, !value.isEmpty
    {
      return value
    }
    return nil
  }

  private static func firstDescription(_ raw: Any?) -> String? {
    if let array = raw as? [[String: Any]],
      let value = array.first?["value"] as? String, !value.isEmpty
    {
      return value
    }
    return nil
  }

  private static func firstDouble(_ raw: Any?) -> Double? {
    if let double = raw as? Double { return double }
    if let int = raw as? Int { return Double(int) }
    if let string = firstString(raw) { return Double(string) }
    return nil
  }

  // MARK: - Open-Meteo fallback

  private static func openMeteoReport(
    manual: String, coordinate: CLLocationCoordinate2D?
  ) async -> ProviderReport? {
    let resolved = await resolveCoordinate(manual: manual, coordinate: coordinate)
    guard let resolved else { return nil }
    var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
    components?.queryItems = [
      URLQueryItem(name: "latitude", value: String(format: "%.4f", resolved.latitude)),
      URLQueryItem(name: "longitude", value: String(format: "%.4f", resolved.longitude)),
      URLQueryItem(
        name: "current",
        value:
          "temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,wind_speed_10m,wind_direction_10m"
      ),
      URLQueryItem(
        name: "daily",
        value:
          "weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,precipitation_probability_max,wind_speed_10m_max"
      ),
      URLQueryItem(name: "timezone", value: "auto"),
      URLQueryItem(name: "forecast_days", value: "7"),
    ]
    guard let url = components?.url else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 6
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    guard
      let (data, response) = try? await URLSession.shared.data(for: request),
      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return formatOpenMeteo(object, label: resolved.label)
  }

  private static func resolveCoordinate(
    manual: String, coordinate: CLLocationCoordinate2D?
  ) async -> (latitude: Double, longitude: Double, label: String)? {
    if !manual.isEmpty {
      if let parsed = parseLatLon(manual) {
        return (parsed.0, parsed.1, manual)
      }
      if let geocoded = await openMeteoGeocode(name: manual) { return geocoded }
      if let coordinate {
        return (coordinate.latitude, coordinate.longitude, manual)
      }
      return nil
    }
    if let coordinate {
      return (coordinate.latitude, coordinate.longitude, "current location")
    }
    return nil
  }

  private static func parseLatLon(_ raw: String) -> (Double, Double)? {
    let parts = raw.split(whereSeparator: { ",;".contains($0) || $0.isWhitespace })
      .map { Double(String($0).trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 2, let lat = parts[0], let lon = parts[1] else { return nil }
    return (lat, lon)
  }

  private static func openMeteoGeocode(name: String) async
    -> (latitude: Double, longitude: Double, label: String)?
  {
    var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
    components?.queryItems = [
      URLQueryItem(name: "name", value: name),
      URLQueryItem(name: "count", value: "1"),
    ]
    guard let url = components?.url else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 4
    guard
      let (data, _) = try? await URLSession.shared.data(for: request),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let results = object["results"] as? [[String: Any]],
      let first = results.first,
      let lat = first["latitude"] as? Double,
      let lon = first["longitude"] as? Double
    else { return nil }
    let label = [first["name"] as? String, first["country"] as? String]
      .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    return (lat, lon, label.isEmpty ? name : label)
  }

  private static func formatOpenMeteo(_ object: [String: Any], label: String) -> ProviderReport? {
    var lines: [String] = ["Location: \(label)"]
    var forecastDayCount = 0
    if let current = object["current"] as? [String: Any] {
      let temp = numberString(current["temperature_2m"]) ?? "?"
      let feels = numberString(current["apparent_temperature"]) ?? "?"
      let humidity = numberString(current["relative_humidity_2m"]) ?? "?"
      let precip = numberString(current["precipitation"]) ?? "0"
      let wind = numberString(current["wind_speed_10m"]) ?? "?"
      let windDir = numberString(current["wind_direction_10m"]) ?? "?"
      let desc = weatherCodeDescription(current["weather_code"] as? Int)
      lines.append("Now: \(desc), \(temp)°C (feels \(feels)°C), humidity \(humidity)%")
      lines.append("Wind: \(wind) km/h @ \(windDir)°")
      lines.append("Precipitation: \(precip) mm")
    }
    if let daily = object["daily"] as? [String: Any],
      let times = daily["time"] as? [String]
    {
      let codes = daily["weather_code"] as? [Int] ?? []
      let mins = (daily["temperature_2m_min"] as? [Double]) ?? []
      let maxs = (daily["temperature_2m_max"] as? [Double]) ?? []
      let precip = (daily["precipitation_sum"] as? [Double]) ?? []
      let chance = (daily["precipitation_probability_max"] as? [Int]) ?? []
      let wind = (daily["wind_speed_10m_max"] as? [Double]) ?? []
      lines.append("")
      forecastDayCount = min(times.count, minimumForecastDays)
      lines.append("Forecast (\(forecastDayCount) days):")
      for index in 0..<forecastDayCount {
        let date = times[index]
        let minT = index < mins.count ? String(format: "%.0f", mins[index]) : "?"
        let maxT = index < maxs.count ? String(format: "%.0f", maxs[index]) : "?"
        let desc = weatherCodeDescription(index < codes.count ? codes[index] : nil)
        let rain = index < precip.count ? String(format: "%.1f", precip[index]) : "0"
        let prob = index < chance.count ? "\(chance[index])" : "0"
        let windMax = index < wind.count ? String(format: "%.0f", wind[index]) : "?"
        lines.append(
          "- \(date): \(minT)–\(maxT)°C, \(desc); wind ≤\(windMax) km/h; rain \(rain) mm (\(prob)%)"
        )
      }
    }
    let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return body.isEmpty
      ? nil
      : ProviderReport(body: body, forecastDayCount: forecastDayCount, coordinate: nil)
  }

  private static func numberString(_ raw: Any?) -> String? {
    if let int = raw as? Int { return "\(int)" }
    if let double = raw as? Double {
      return double.truncatingRemainder(dividingBy: 1) == 0
        ? String(format: "%.0f", double)
        : String(format: "%.1f", double)
    }
    if let s = raw as? String, !s.isEmpty { return s }
    return nil
  }

  /// WMO weather code descriptions (https://open-meteo.com/en/docs).
  private static func weatherCodeDescription(_ code: Int?) -> String {
    guard let code else { return "—" }
    switch code {
    case 0: return "Clear"
    case 1: return "Mostly clear"
    case 2: return "Partly cloudy"
    case 3: return "Overcast"
    case 45, 48: return "Fog"
    case 51, 53, 55: return "Drizzle"
    case 56, 57: return "Freezing drizzle"
    case 61, 63, 65: return "Rain"
    case 66, 67: return "Freezing rain"
    case 71, 73, 75: return "Snow"
    case 77: return "Snow grains"
    case 80, 81, 82: return "Rain showers"
    case 85, 86: return "Snow showers"
    case 95: return "Thunderstorm"
    case 96, 99: return "Thunderstorm with hail"
    default: return "Code \(code)"
    }
  }

  // MARK: - Moon phase (locally computed)

  static func moonPhaseLine(for date: Date) -> String {
    let phase = moonPhase(for: date)
    return "Moon: \(phase.name) (illumination \(Int(phase.illumination * 100))%)"
  }

  /// Synodic-month approximation; illumination 0…1, accurate to ~1 day.
  static func moonPhase(for date: Date) -> (name: String, illumination: Double) {
    let synodicMonth = 29.530588853
    let reference = Date(timeIntervalSince1970: 947_182_440)  // Jan 6, 2000 18:14 UTC new moon
    let elapsed = date.timeIntervalSince(reference) / 86_400
    var age = elapsed.truncatingRemainder(dividingBy: synodicMonth)
    if age < 0 { age += synodicMonth }
    let illumination = (1 - cos(2 * .pi * age / synodicMonth)) / 2
    let name: String
    switch age {
    case ..<1.84566: name = "New Moon"
    case ..<5.53699: name = "Waxing Crescent"
    case ..<9.22831: name = "First Quarter"
    case ..<12.91963: name = "Waxing Gibbous"
    case ..<16.61096: name = "Full Moon"
    case ..<20.30228: name = "Waning Gibbous"
    case ..<23.99361: name = "Last Quarter"
    case ..<27.68493: name = "Waning Crescent"
    default: name = "New Moon"
    }
    return (name, illumination)
  }
}

enum WebSearchService {
  private static let userAgent =
    "PocketMai/1.0 (iOS; +https://github.com/trufae/mai)"
  private static let requestTimeout: TimeInterval = 8
  private static let maxQueryLength = 240
  private static let maxWebResults = 6
  private static let maxWikipediaSummaries = 3

  private struct SearXNGConfiguration: Sendable {
    let baseURL: URL
    let authorization: String?
  }

  static func searchContext(
    query: String, provider: WebSearchProvider, settings: AppSettings
  ) async -> String? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let q = String(trimmed.prefix(maxQueryLength))

    let ollamaEndpoint = Self.ollamaEndpoint(in: settings)
    let searXNGConfiguration = Self.searXNGConfiguration(in: settings.toolSettings)
    if provider == .searXNG, searXNGConfiguration == nil {
      return """
        Web Search tool (query: "\(q)"):

        SearXNG: URL is not configured.
        """
    }

    let useSearXNG = (provider == .searXNG || provider == .all) && searXNGConfiguration != nil
    let useOllama = (provider == .ollama || provider == .all) && ollamaEndpoint != nil
    let useDDG = provider == .duckDuckGo || provider == .all
    let useWiki = provider == .wikipedia || provider == .all

    async let searXNG: String? =
      useSearXNG ? searXNG(query: q, configuration: searXNGConfiguration!) : nil
    async let ollama: String? =
      useOllama ? ollamaWebSearch(query: q, endpoint: ollamaEndpoint!) : nil
    async let ddg: String? = useDDG ? duckDuckGo(query: q) : nil
    async let wiki: String? = useWiki ? wikipedia(query: q) : nil
    var sections: [String] = []
    if let s = await searXNG { sections.append(s) }
    if let s = await ollama { sections.append(s) }
    if let s = await ddg { sections.append(s) }
    if let s = await wiki { sections.append(s) }

    if sections.isEmpty {
      async let ddgFallback: String? = useDDG ? nil : duckDuckGo(query: q)
      async let wikiFallback: String? = useWiki ? nil : wikipedia(query: q)
      if let s = await ddgFallback { sections.append(s) }
      if let s = await wikiFallback { sections.append(s) }
    }

    guard !sections.isEmpty else { return nil }
    let header = "Web Search tool (query: \"\(q)\"):"
    return ([header] + sections).joined(separator: "\n\n")
  }

  static func ollamaEndpoint(in settings: AppSettings) -> OpenAIEndpoint? {
    settings.openAIEndpoints.first { endpoint in
      guard endpoint.isEnabled else { return false }
      let host = URL(string: endpoint.baseURL)?.host?.lowercased() ?? ""
      let trimmedKey = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      return host.hasSuffix("ollama.com") && !trimmedKey.isEmpty
    }
  }

  private static func searXNGConfiguration(in settings: NativeToolSettings) -> SearXNGConfiguration?
  {
    let trimmedURL = settings.webSearchSearXNGURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedURL.isEmpty else { return nil }
    let urlString = trimmedURL.contains("://") ? trimmedURL : "https://\(trimmedURL)"
    guard
      let url = URL(string: urlString),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      url.host != nil
    else {
      return nil
    }

    let username = settings.webSearchSearXNGUsername.trimmingCharacters(in: .whitespacesAndNewlines)
    let password = settings.webSearchSearXNGPassword.trimmingCharacters(in: .whitespacesAndNewlines)
    let authorization: String?
    if username.isEmpty && password.isEmpty {
      authorization = nil
    } else {
      let credentials = "\(username):\(password)"
      let encoded = Data(credentials.utf8).base64EncodedString()
      authorization = "Basic \(encoded)"
    }
    return SearXNGConfiguration(baseURL: url, authorization: authorization)
  }

  // MARK: - Ollama Web Search

  private static func ollamaWebSearch(query: String, endpoint: OpenAIEndpoint) async -> String? {
    let trimmedKey = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedKey.isEmpty,
      let url = URL(string: "https://ollama.com/api/web_search")
    else {
      return nil
    }
    let authorization = "Bearer \(trimmedKey)"
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(authorization, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = requestTimeout
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])

    let delegate = RedirectPreservingDelegate(
      authorization: authorization, originalRequest: request)
    guard
      let (data, response) = try? await URLSession.shared.data(for: request, delegate: delegate),
      let http = response as? HTTPURLResponse,
      (200..<300).contains(http.statusCode),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }

    let rawResults =
      (object["results"] as? [[String: Any]])
      ?? (object["data"] as? [[String: Any]]) ?? []
    let lines = rawResults.prefix(maxWebResults).compactMap { item -> String? in
      let title = ((item["title"] as? String) ?? (item["name"] as? String) ?? "").cleaned
      let urlString =
        ((item["url"] as? String) ?? (item["link"] as? String) ?? "").cleaned
      let snippet =
        ((item["content"] as? String) ?? (item["snippet"] as? String)
          ?? (item["text"] as? String) ?? "")
        .cleaned
      guard !title.isEmpty || !snippet.isEmpty else { return nil }
      var entry = "- \(title.isEmpty ? urlString : title)"
      if !snippet.isEmpty {
        entry += "\n  \(snippet)"
      }
      if !urlString.isEmpty, urlString != title {
        entry += "\n  \(urlString)"
      }
      return entry
    }
    guard !lines.isEmpty else { return nil }
    return "Ollama Web Search:\n" + lines.joined(separator: "\n")
  }

  // MARK: - SearXNG

  private static func searXNG(query: String, configuration: SearXNGConfiguration) async -> String? {
    guard let url = searXNGSearchURL(query: query, baseURL: configuration.baseURL),
      let object = await getJSON(url: url, authorization: configuration.authorization)
        as? [String: Any]
    else {
      return nil
    }

    var lines: [String] = []
    if let answers = object["answers"] as? [String] {
      lines.append(
        contentsOf: answers.prefix(3).compactMap { answer -> String? in
          let cleaned = stripHTML(answer)
          return cleaned.isEmpty ? nil : "Answer: \(cleaned)"
        })
    }

    let rawResults = object["results"] as? [[String: Any]] ?? []
    var seenURLs = Set<String>()
    var resultCount = 0
    for item in rawResults {
      if resultCount >= maxWebResults { break }
      let title = stripHTML(((item["title"] as? String) ?? "").cleaned)
      let urlString = ((item["url"] as? String) ?? "").cleaned
      let snippet = stripHTML(
        ((item["content"] as? String) ?? (item["snippet"] as? String) ?? "").cleaned)
      guard !title.isEmpty || !snippet.isEmpty || !urlString.isEmpty else { continue }
      let key = urlString.isEmpty ? title : urlString
      if seenURLs.contains(key) { continue }
      seenURLs.insert(key)

      var entry = "- \(title.isEmpty ? urlString : title)"
      if !snippet.isEmpty {
        entry += "\n  \(snippet)"
      }
      if !urlString.isEmpty, urlString != title {
        entry += "\n  \(urlString)"
      }
      lines.append(entry)
      resultCount += 1
    }

    guard !lines.isEmpty else { return nil }
    return "SearXNG results:\n" + lines.joined(separator: "\n")
  }

  private static func searXNGSearchURL(query: String, baseURL: URL) -> URL? {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.path = searXNGSearchPath(from: components.path)
    var queryItems = components.queryItems ?? []
    queryItems.removeAll { item in
      let name = item.name.lowercased()
      return name == "q" || name == "format"
    }
    queryItems.append(URLQueryItem(name: "q", value: query))
    queryItems.append(URLQueryItem(name: "format", value: "json"))
    components.queryItems = queryItems
    return components.url
  }

  private static func searXNGSearchPath(from path: String) -> String {
    var trimmed = path
    while trimmed.hasSuffix("/") {
      trimmed.removeLast()
    }
    if trimmed.isEmpty {
      return "/search"
    }
    if trimmed.hasSuffix("/search") {
      return trimmed
    }
    return "\(trimmed)/search"
  }

  // MARK: - DuckDuckGo

  private static func duckDuckGo(query: String) async -> String? {
    async let instant: String? = duckDuckGoInstant(query: query)
    async let web: String? = duckDuckGoWeb(query: query)
    var blocks: [String] = []
    if let s = await instant { blocks.append(s) }
    if let s = await web { blocks.append(s) }
    return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
  }

  private static func duckDuckGoInstant(query: String) async -> String? {
    var components = URLComponents(string: "https://api.duckduckgo.com/")
    components?.queryItems = [
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "format", value: "json"),
      URLQueryItem(name: "no_redirect", value: "1"),
      URLQueryItem(name: "no_html", value: "1"),
      URLQueryItem(name: "skip_disambig", value: "1"),
    ]
    guard let url = components?.url,
      let object = await getJSON(url: url) as? [String: Any]
    else {
      return nil
    }
    var lines: [String] = []
    if let abstract = (object["AbstractText"] as? String)?.cleaned, !abstract.isEmpty {
      let source = (object["AbstractSource"] as? String) ?? "DuckDuckGo"
      lines.append("\(source): \(abstract)")
      if let urlString = (object["AbstractURL"] as? String)?.cleaned, !urlString.isEmpty {
        lines.append("  Source: \(urlString)")
      }
    }
    if let answer = (object["Answer"] as? String)?.cleaned, !answer.isEmpty {
      let type = (object["AnswerType"] as? String) ?? "answer"
      lines.append("Answer (\(type)): \(answer)")
    }
    if let definition = (object["Definition"] as? String)?.cleaned, !definition.isEmpty {
      let source = (object["DefinitionSource"] as? String) ?? "Definition"
      lines.append("\(source): \(definition)")
    }
    if let topics = object["RelatedTopics"] as? [[String: Any]] {
      let topicLines = topics.prefix(5).compactMap { item -> String? in
        guard let text = (item["Text"] as? String)?.cleaned, !text.isEmpty else { return nil }
        if let urlString = (item["FirstURL"] as? String)?.cleaned, !urlString.isEmpty {
          return "- \(text) (\(urlString))"
        }
        return "- \(text)"
      }
      if !topicLines.isEmpty {
        lines.append("Related topics:")
        lines.append(contentsOf: topicLines)
      }
    }
    guard !lines.isEmpty else { return nil }
    return "DuckDuckGo Instant:\n" + lines.joined(separator: "\n")
  }

  private static func duckDuckGoWeb(query: String) async -> String? {
    var components = URLComponents(string: "https://html.duckduckgo.com/html/")
    components?.queryItems = [URLQueryItem(name: "q", value: query)]
    guard let url = components?.url,
      let html = await getString(url: url, accept: "text/html")
    else {
      return nil
    }
    let results = parseDuckDuckGoHTML(html, limit: maxWebResults)
    guard !results.isEmpty else { return nil }
    let body = results.map { result in
      var entry = "- \(result.title)"
      if !result.snippet.isEmpty {
        entry += "\n  \(result.snippet)"
      }
      if !result.url.isEmpty {
        entry += "\n  \(result.url)"
      }
      return entry
    }.joined(separator: "\n")
    return "DuckDuckGo results:\n" + body
  }

  private struct WebResult {
    let title: String
    let url: String
    let snippet: String
  }

  private static func parseDuckDuckGoHTML(_ html: String, limit: Int) -> [WebResult] {
    let pattern =
      #"class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>([\s\S]*?)</a>[\s\S]{0,2000}?class=\"result__snippet\"[^>]*>([\s\S]*?)</a>"#
    guard
      let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else {
      return []
    }
    let nsHTML = html as NSString
    let matches = regex.matches(
      in: html, options: [], range: NSRange(location: 0, length: nsHTML.length))
    var results: [WebResult] = []
    var seenURLs = Set<String>()
    for match in matches {
      if results.count >= limit { break }
      guard match.numberOfRanges == 4 else { continue }
      let rawURL = nsHTML.substring(with: match.range(at: 1))
      let rawTitle = nsHTML.substring(with: match.range(at: 2))
      let rawSnippet = nsHTML.substring(with: match.range(at: 3))
      let title = stripHTML(rawTitle)
      let snippet = stripHTML(rawSnippet)
      let url = decodeDDGRedirect(rawURL)
      guard !title.isEmpty || !snippet.isEmpty else { continue }
      let key = url.isEmpty ? title : url
      if seenURLs.contains(key) { continue }
      seenURLs.insert(key)
      results.append(WebResult(title: title, url: url, snippet: snippet))
    }
    return results
  }

  private static func decodeDDGRedirect(_ raw: String) -> String {
    var s = raw.cleaned
    if s.hasPrefix("//") { s = "https:" + s }
    guard let comps = URLComponents(string: s) else { return s }
    if let uddg = comps.queryItems?.first(where: { $0.name == "uddg" })?.value,
      !uddg.isEmpty
    {
      return uddg.removingPercentEncoding ?? uddg
    }
    return s
  }

  // MARK: - Wikipedia

  private static func wikipedia(query: String) async -> String? {
    guard let titles = await wikipediaSearch(query: query, limit: maxWikipediaSummaries),
      !titles.isEmpty
    else {
      return nil
    }
    let summaries = await withTaskGroup(of: (Int, String?).self, returning: [String?].self) {
      group in
      for (index, title) in titles.enumerated() {
        group.addTask {
          (index, await wikipediaSummary(title: title))
        }
      }
      var collected: [String?] = Array(repeating: nil, count: titles.count)
      for await (index, summary) in group {
        if collected.indices.contains(index) {
          collected[index] = summary
        }
      }
      return collected
    }
    let entries = summaries.compactMap { $0 }
    guard !entries.isEmpty else { return nil }
    return "Wikipedia:\n" + entries.joined(separator: "\n\n")
  }

  private static func wikipediaSearch(query: String, limit: Int) async -> [String]? {
    var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")
    components?.queryItems = [
      URLQueryItem(name: "action", value: "query"),
      URLQueryItem(name: "list", value: "search"),
      URLQueryItem(name: "srsearch", value: query),
      URLQueryItem(name: "format", value: "json"),
      URLQueryItem(name: "srlimit", value: String(limit)),
      URLQueryItem(name: "origin", value: "*"),
    ]
    guard let url = components?.url,
      let object = await getJSON(url: url) as? [String: Any],
      let queryObject = object["query"] as? [String: Any],
      let results = queryObject["search"] as? [[String: Any]]
    else {
      return nil
    }
    return results.compactMap { $0["title"] as? String }
  }

  private static func wikipediaSummary(title: String) async -> String? {
    let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
    let encoded = title.addingPercentEncoding(withAllowedCharacters: allowed) ?? title
    guard
      let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)"),
      let object = await getJSON(url: url) as? [String: Any]
    else {
      return nil
    }
    guard let extract = (object["extract"] as? String)?.cleaned, !extract.isEmpty else {
      return nil
    }
    let outTitle = (object["title"] as? String) ?? title
    var entry = "- \(outTitle): \(extract)"
    if let urls = object["content_urls"] as? [String: Any],
      let desktop = urls["desktop"] as? [String: Any],
      let page = (desktop["page"] as? String)?.cleaned,
      !page.isEmpty
    {
      entry += "\n  \(page)"
    }
    return entry
  }

  // MARK: - HTTP helpers

  private static func getJSON(url: URL, authorization: String? = nil) async -> Any? {
    guard
      let data = await getData(url: url, accept: "application/json", authorization: authorization)
    else {
      return nil
    }
    return try? JSONSerialization.jsonObject(with: data)
  }

  private static func getString(url: URL, accept: String, authorization: String? = nil) async
    -> String?
  {
    guard let data = await getData(url: url, accept: accept, authorization: authorization) else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  private static func getData(url: URL, accept: String, authorization: String? = nil) async
    -> Data?
  {
    var request = URLRequest(url: url)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(accept, forHTTPHeaderField: "Accept")
    if let authorization {
      request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }
    request.timeoutInterval = requestTimeout
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
        return nil
      }
      return data
    } catch {
      return nil
    }
  }

  // MARK: - HTML cleanup

  private static func stripHTML(_ s: String) -> String {
    var t = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    let entities: [(String, String)] = [
      ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
      ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"),
      ("&nbsp;", " "), ("&hellip;", "…"), ("&mdash;", "—"), ("&ndash;", "–"),
    ]
    for (entity, replacement) in entities {
      t = t.replacingOccurrences(of: entity, with: replacement)
    }
    return t.cleaned
  }
}

extension String {
  fileprivate var cleaned: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

enum MCPHTTPClient {
  private static let protocolVersion = "2025-06-18"
  private static let protocolVersionHeader = "MCP-Protocol-Version"
  private static let sessionIDHeader = "Mcp-Session-Id"
  private static let sessions = MCPSessionStore()

  struct Catalog: Sendable {
    var tools: [MCPToolDescriptor]
    var resources: [MCPResourceDescriptor]
  }

  static func fetchCatalog(server: MCPServer) async throws -> Catalog {
    var firstError: Error?

    let tools: [MCPToolDescriptor]
    do {
      tools = try await fetchTools(server: server)
    } catch {
      if isMethodNotFound(error) {
        tools = []
      } else {
        firstError = error
        tools = []
      }
    }

    let resources: [MCPResourceDescriptor]
    do {
      resources = try await fetchResources(server: server)
    } catch {
      if isMethodNotFound(error) {
        resources = []
      } else {
        firstError = firstError ?? error
        resources = []
      }
    }

    if tools.isEmpty, resources.isEmpty, let firstError {
      throw firstError
    }
    return Catalog(tools: tools, resources: resources)
  }

  static func fetchTools(server: MCPServer) async throws -> [MCPToolDescriptor] {
    let data = try await send(server: server, method: "tools/list")
    guard let raw = jsonObject(from: data) else {
      throw ChatProviderError.providerRequestFailed("MCP returned non-JSON response.")
    }
    if let error = responseError(from: raw) {
      throw error
    }
    let result = raw["result"] as? [String: Any] ?? [:]
    let toolList = result["tools"] as? [[String: Any]] ?? []
    return toolList.compactMap { toolDict -> MCPToolDescriptor? in
      guard let name = toolDict["name"] as? String else { return nil }
      let description = (toolDict["description"] as? String) ?? ""
      var parametersJSON = ""
      if let schema = toolDict["inputSchema"],
        let pdata = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]),
        let pjson = String(data: pdata, encoding: .utf8)
      {
        parametersJSON = pjson
      }
      return MCPToolDescriptor(
        name: name, description: description, parametersJSON: parametersJSON)
    }
  }

  static func fetchResources(server: MCPServer) async throws -> [MCPResourceDescriptor] {
    let data = try await send(server: server, method: "resources/list")
    guard let raw = jsonObject(from: data) else {
      throw ChatProviderError.providerRequestFailed("MCP returned non-JSON response.")
    }
    if let error = responseError(from: raw) {
      throw error
    }
    let result = raw["result"] as? [String: Any] ?? [:]
    let resources = result["resources"] as? [[String: Any]] ?? []
    return resources.compactMap { resource -> MCPResourceDescriptor? in
      guard let uri = resource["uri"] as? String, !uri.isEmpty else { return nil }
      return MCPResourceDescriptor(
        uri: uri,
        name: (resource["name"] as? String) ?? "",
        description: (resource["description"] as? String) ?? "",
        mimeType: (resource["mimeType"] as? String) ?? "")
    }
  }

  static func readResource(server: MCPServer, uri: String) async throws -> String {
    let params: [String: AnyCodable] = ["uri": AnyCodable(uri)]
    let data = try await send(server: server, method: "resources/read", params: params)
    let responseData: Data
    if let raw = jsonObject(from: data),
      let error = responseError(from: raw)
    {
      throw error
    } else if let raw = jsonObject(from: data),
      let normalized = try? JSONSerialization.data(withJSONObject: raw)
    {
      responseData = normalized
    } else {
      responseData = data
    }
    let decoded = try JSONDecoder().decode(MCPResourceReadResponse.self, from: responseData)
    if let err = decoded.error {
      let message = err.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let codeSuffix = err.code.map { " (code \($0))" } ?? ""
      throw ChatProviderError.providerRequestFailed(
        "MCP error\(codeSuffix): \(message.isEmpty ? "unknown" : message)")
    }
    let rendered = decoded.result?.contents?.compactMap(renderResourceContent) ?? []
    let text = rendered.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? "(empty resource)" : text
  }

  static func callTool(
    server: MCPServer, name: String, arguments: [String: AgentToolArgumentValue]
  ) async throws -> String {
    let argsCodable = arguments.compactMapValues(anyCodable)
    let params: [String: AnyCodable] = [
      "name": AnyCodable(name),
      "arguments": AnyCodable(argsCodable),
    ]
    let data = try await send(server: server, method: "tools/call", params: params)
    let responseData: Data
    if let raw = jsonObject(from: data),
      let error = responseError(from: raw)
    {
      throw error
    } else if let raw = jsonObject(from: data),
      let normalized = try? JSONSerialization.data(withJSONObject: raw)
    {
      responseData = normalized
    } else {
      responseData = data
    }
    let decoded = try JSONDecoder().decode(MCPToolCallResponse.self, from: responseData)
    if let err = decoded.error {
      let message = err.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let codeSuffix = err.code.map { " (code \($0))" } ?? ""
      throw ChatProviderError.providerRequestFailed(
        "MCP error\(codeSuffix): \(message.isEmpty ? "unknown" : message)")
    }
    let parts = decoded.result?.content?.compactMap { $0.text } ?? []
    let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    if decoded.result?.isError == true {
      return "Error: \(text.isEmpty ? "tool reported failure" : text)"
    }
    return text.isEmpty ? "(no output)" : text
  }

  static func resetSession(for serverID: UUID) async {
    await sessions.reset(serverID)
  }

  static func resetAllSessions() async {
    await sessions.resetAll()
  }

  private static func send(
    server: MCPServer,
    method: String,
    params: [String: AnyCodable]? = nil,
    retryingInvalidSession: Bool = true
  ) async throws -> Data {
    let sessionID = try await ensureSession(for: server)
    do {
      let response = try await sendRaw(
        server: server,
        method: method,
        params: params,
        sessionID: sessionID)
      if let raw = jsonObject(from: response.data),
        let error = responseError(from: raw)
      {
        if retryingInvalidSession && error.isInvalidSessionID {
          await sessions.reset(server.id)
          return try await send(
            server: server,
            method: method,
            params: params,
            retryingInvalidSession: false)
        }
        throw error
      }
      return response.data
    } catch {
      if retryingInvalidSession && isInvalidSessionID(error) {
        await sessions.reset(server.id)
        return try await send(
          server: server,
          method: method,
          params: params,
          retryingInvalidSession: false)
      }
      throw error
    }
  }

  private static func ensureSession(for server: MCPServer) async throws -> String? {
    let baseURL = try normalizedBaseURL(for: server).absoluteString
    if let cached = await sessions.session(for: server.id, baseURL: baseURL) {
      return cached.id
    }

    let response = try await sendRaw(
      server: server,
      method: "initialize",
      params: initializeParams,
      sessionID: nil)
    if let raw = jsonObject(from: response.data),
      let error = responseError(from: raw)
    {
      if error.isMethodNotFound {
        await sessions.set(nil, for: server.id, baseURL: baseURL)
        return nil
      }
      throw error
    }

    await sessions.set(response.sessionID, for: server.id, baseURL: baseURL)
    try await sendInitializedNotification(server: server, sessionID: response.sessionID)
    return response.sessionID
  }

  private static func sendInitializedNotification(server: MCPServer, sessionID: String?)
    async throws
  {
    let response = try await sendRaw(
      server: server,
      method: "notifications/initialized",
      params: nil,
      sessionID: sessionID,
      isNotification: true)
    if let raw = jsonObject(from: response.data),
      let error = responseError(from: raw)
    {
      throw error
    }
  }

  private static func sendRaw(
    server: MCPServer,
    method: String,
    params: [String: AnyCodable]? = nil,
    sessionID: String?,
    isNotification: Bool = false
  ) async throws -> MCPHTTPResponse {
    let url = try normalizedBaseURL(for: server)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue(protocolVersion, forHTTPHeaderField: protocolVersionHeader)
    if let sessionID, !sessionID.isEmpty {
      request.setValue(sessionID, forHTTPHeaderField: sessionIDHeader)
    }
    request.timeoutInterval = 8
    let body = JSONRPCRequest(
      id: isNotification ? nil : Int.random(in: 1...Int.max),
      method: method,
      params: params)
    request.httpBody = try JSONEncoder().encode(body)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      return MCPHTTPResponse(data: data, sessionID: nil)
    }
    if !(200..<300).contains(http.statusCode) {
      let snippet = String(data: data.prefix(400), encoding: .utf8) ?? ""
      throw MCPHTTPError(statusCode: http.statusCode, body: snippet, hadSessionID: sessionID != nil)
    }
    let returnedSessionID =
      http.value(forHTTPHeaderField: sessionIDHeader)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return MCPHTTPResponse(
      data: data, sessionID: returnedSessionID?.isEmpty == false ? returnedSessionID : nil)
  }

  private static func normalizedBaseURL(for server: MCPServer) throws -> URL {
    let baseURL = server.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard server.hasValidEndpointURL, let url = URL(string: baseURL) else {
      throw ChatProviderError.invalidEndpoint(server.baseURL)
    }
    return url
  }

  private static var initializeParams: [String: AnyCodable] {
    [
      "protocolVersion": AnyCodable(protocolVersion),
      "capabilities": AnyCodable([String: AnyCodable]()),
      "clientInfo": AnyCodable([
        "name": AnyCodable("PocketMai"),
        "version": AnyCodable(clientVersion),
      ]),
    ]
  }

  private static var clientVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
  }

  private static func responseError(from raw: [String: Any]) -> MCPResponseError? {
    guard let err = raw["error"] as? [String: Any] else { return nil }
    let message = (err["message"] as? String) ?? "unknown"
    return MCPResponseError(code: err["code"] as? Int, message: message)
  }

  private static func isInvalidSessionID(_ error: Error) -> Bool {
    if let error = error as? MCPHTTPError {
      return error.isInvalidSessionID
    }
    if let error = error as? MCPResponseError {
      return error.isInvalidSessionID
    }
    return error.localizedDescription.localizedCaseInsensitiveContains("invalid session")
  }

  private static func isMethodNotFound(_ error: Error) -> Bool {
    if let error = error as? MCPResponseError {
      return error.isMethodNotFound
    }
    return error.localizedDescription.localizedCaseInsensitiveContains("method not found")
  }

  private static func jsonObject(from data: Data) -> [String: Any]? {
    if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      return raw
    }
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    for event in text.components(separatedBy: "\n\n") {
      let payload = event.split(whereSeparator: \.isNewline)
        .compactMap { line -> String? in
          guard line.hasPrefix("data:") else { return nil }
          return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !payload.isEmpty,
        let payloadData = payload.data(using: .utf8),
        let raw = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
      else {
        continue
      }
      return raw
    }
    return nil
  }

  private static func anyCodable(_ value: AgentToolArgumentValue) -> AnyCodable? {
    switch value {
    case .string(let value):
      return AnyCodable(value)
    case .bool(let value):
      return AnyCodable(value)
    case .int(let value):
      return AnyCodable(value)
    case .double(let value):
      return AnyCodable(value)
    case .object(let value):
      return AnyCodable(value.compactMapValues(anyCodable))
    case .array(let value):
      return AnyCodable(value.compactMap(anyCodable))
    case .null:
      return nil
    }
  }

  private static func renderResourceContent(_ content: MCPResourceReadResponse.Content) -> String? {
    let headerParts = [content.uri, content.mimeType]
      .compactMap { value -> String? in
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
      }
    let header = headerParts.isEmpty ? "" : "[\(headerParts.joined(separator: " "))]\n"
    if let text = content.text, !text.isEmpty {
      return header + text
    }
    guard let blob = content.blob, !blob.isEmpty else {
      return header.isEmpty ? nil : header + "(empty resource content)"
    }
    guard let data = Data(base64Encoded: blob) else {
      return header + "(binary resource, invalid base64 payload)"
    }
    if let text = String(data: data, encoding: .utf8), isTextLikeMIMEType(content.mimeType) {
      return header + text
    }
    return header + "(binary resource, \(data.count) bytes)"
  }

  private static func isTextLikeMIMEType(_ value: String?) -> Bool {
    let lower = value?.lowercased() ?? ""
    return lower.contains("text") || lower.contains("json") || lower.contains("xml")
      || lower.contains("javascript") || lower.contains("markdown")
  }
}

private actor MCPSessionStore {
  private var sessions: [UUID: MCPSession] = [:]

  func session(for serverID: UUID, baseURL: String) -> MCPSession? {
    guard let session = sessions[serverID], session.baseURL == baseURL else {
      return nil
    }
    return session
  }

  func set(_ sessionID: String?, for serverID: UUID, baseURL: String) {
    sessions[serverID] = MCPSession(id: sessionID, baseURL: baseURL)
  }

  func reset(_ serverID: UUID) {
    sessions[serverID] = nil
  }

  func resetAll() {
    sessions.removeAll()
  }
}

private struct MCPSession: Sendable {
  var id: String?
  var baseURL: String
}

private struct MCPHTTPResponse {
  var data: Data
  var sessionID: String?
}

private struct MCPHTTPError: LocalizedError {
  var statusCode: Int
  var body: String
  var hadSessionID: Bool

  var isInvalidSessionID: Bool {
    statusCode == 404 && hadSessionID
      || body.localizedCaseInsensitiveContains("invalid session")
  }

  var errorDescription: String? {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "MCP HTTP \(statusCode)." : "MCP HTTP \(statusCode): \(trimmed)"
  }
}

private struct MCPResponseError: LocalizedError {
  var code: Int?
  var message: String

  var isInvalidSessionID: Bool {
    message.localizedCaseInsensitiveContains("invalid session")
  }

  var isMethodNotFound: Bool {
    code == -32601
  }

  var errorDescription: String? {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    let codeSuffix = code.map { " (code \($0))" } ?? ""
    return "MCP error\(codeSuffix): \(trimmed.isEmpty ? "unknown" : trimmed)"
  }
}

private struct JSONRPCRequest: Encodable {
  var jsonrpc = "2.0"
  var id: Int?
  var method: String
  var params: [String: AnyCodable]?
}

private struct MCPToolCallResponse: Decodable {
  struct Result: Decodable {
    var content: [ContentPart]?
    var isError: Bool?
  }
  struct ContentPart: Decodable {
    var type: String?
    var text: String?
  }
  struct Err: Decodable {
    var code: Int?
    var message: String?
  }
  var result: Result?
  var error: Err?
}

private struct MCPResourceReadResponse: Decodable {
  struct Result: Decodable {
    var contents: [Content]?
  }
  struct Content: Decodable {
    var uri: String?
    var mimeType: String?
    var text: String?
    var blob: String?
  }
  struct Err: Decodable {
    var code: Int?
    var message: String?
  }
  var result: Result?
  var error: Err?
}
