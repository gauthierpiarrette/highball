import Foundation

/// Tiny localization layer: English strings are the keys; French ships first.
/// (A proper String Catalog needs an Xcode project; this keeps SwiftPM-only builds localized.)
func L(_ en: String) -> String {
    guard Locale.preferredLanguages.first?.hasPrefix("fr") == true else { return en }
    return L10n.fr[en] ?? en
}

enum L10n {
    static let fr: [String: String] = [
        // Sidebar & shell
        "Bottles": "Bouteilles",
        "Engine": "Moteur",
        "New Bottle": "Nouvelle bouteille",
        "No bottle selected": "Aucune bouteille sélectionnée",
        "Create a bottle to install Steam and play.": "Créez une bouteille pour installer Steam et jouer.",
        "Stop all processes": "Arrêter tous les processus",
        "Delete bottle…": "Supprimer la bouteille…",
        "Delete": "Supprimer",
        "Cancel": "Annuler",
        "Something went wrong": "Un problème est survenu",

        // Bottle view
        "Programs": "Programmes",
        "Nothing installed yet — add a launcher below.": "Rien d’installé pour l’instant — ajoutez un launcher ci-dessous.",
        "Run": "Lancer",
        "Games": "Jeux",
        "Play": "Jouer",
        "Install a launcher": "Installer un launcher",
        "Kernel anti-cheat titles (Valorant, Fortnite, Destiny 2…) can’t work through Wine — check the compatibility database before big downloads.":
            "Les jeux à anti-cheat noyau (Valorant, Fortnite, Destiny 2…) ne peuvent pas fonctionner via Wine — consultez la base de compatibilité avant les gros téléchargements.",
        "Graphics & compatibility": "Graphismes et compatibilité",
        "Renderer": "Moteur de rendu",
        "Synchronization": "Synchronisation",
        "Windows version": "Version de Windows",
        "Metal performance HUD": "HUD de performance Metal",
        "Advertise AVX to games (Rosetta)": "Annoncer AVX aux jeux (Rosetta)",
        "Open C: drive": "Ouvrir le disque C:",
        "Stop all": "Tout arrêter",
        "Renderer override": "Forcer un moteur de rendu",
        "Bottle default": "Réglage de la bouteille",
        "Remove from list": "Retirer de la liste",
        "None — required for Steam/CEF launchers": "Aucune — requise pour Steam et les launchers CEF",
        "msync — fastest for most games": "msync — le plus rapide pour la plupart des jeux",
        "DXMT — D3D10/11 → Metal (default)": "DXMT — D3D10/11 → Metal (défaut)",
        "D3DMetal — D3D11/12, Apple": "D3DMetal — D3D11/12, Apple",
        "DXVK — D3D9/10/11 → Vulkan": "DXVK — D3D9/10/11 → Vulkan",
        "WineD3D — slow fallback": "WineD3D — solution de repli, lent",
        "D3DMetal (needed for DirectX 12) requires accepting Apple’s Game Porting Toolkit license.":
            "D3DMetal (nécessaire pour DirectX 12) demande d’accepter la licence du Game Porting Toolkit d’Apple.",
        "Review license…": "Lire la licence…",

        // Sheets & dialogs
        "New bottle": "Nouvelle bouteille",
        "Name": "Nom",
        "Install Steam in it (recommended)": "Y installer Steam (recommandé)",
        "A bottle is an isolated Windows environment. First boot takes about 90 seconds; the Steam install adds a download and a slow one-time client update.":
            "Une bouteille est un environnement Windows isolé. Le premier démarrage prend environ 90 secondes ; l’installation de Steam ajoute un téléchargement et une longue mise à jour initiale.",
        "Create": "Créer",
        "Done": "Terminé",
        "Hide": "Masquer",
        "Close": "Fermer",
        "Details": "Détails",
        "Run and add to Programs": "Lancer et ajouter aux programmes",
        "Keep current": "Garder l’actuel",
        "Accept & enable D3DMetal": "Accepter et activer D3DMetal",
        "Non-commercial use only · no modification · Apple hardware only":
            "Usage non commercial uniquement · aucune modification · matériel Apple uniquement",

        // Onboarding
        "Run Windows games on your Mac. Highball downloads a verified Wine engine (~500 MB) from public upstream releases — nothing is hosted by Highball itself.":
            "Jouez à vos jeux Windows sur votre Mac. Highball télécharge un moteur Wine vérifié (~500 Mo) depuis des publications publiques — Highball n’héberge aucun binaire.",
        "Rosetta 2 is required": "Rosetta 2 est requis",
        "Enable D3DMetal (DirectX 12 support)": "Activer D3DMetal (prise en charge de DirectX 12)",
        "Requires accepting": "Nécessite d’accepter",
        "Apple’s Game Porting Toolkit license": "la licence du Game Porting Toolkit d’Apple",
        "Install engine": "Installer le moteur",
        "Installing…": "Installation…",

        // Status pills
        "Verified": "Vérifié",
        "Reported": "Signalé",
        "Community": "Communauté",
        "Blocked — anti-cheat": "Bloqué — anti-cheat",
    ]
}
