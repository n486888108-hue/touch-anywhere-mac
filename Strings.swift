// Tiny localisation helper: English by default, Chinese when the system language is Chinese.
import Foundation

func T(_ en: String, _ zh: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? zh : en
}
