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
        #"A bottle name can't contain \ / : * ? " < > | — Windows paths forbid them, which would break the bottle."#:
            #"Un nom de bouteille ne peut pas contenir \ / : * ? " < > | — Windows les interdit dans les chemins, ce qui casserait la bouteille."#,
        "The bottle name is empty.": "Le nom de la bouteille est vide.",
        "The bottle name contains control characters.": "Le nom de la bouteille contient des caractères de contrôle.",
        "A bottle name can't start with a dot.": "Un nom de bouteille ne peut pas commencer par un point.",
        "A bottle name can't end with a dot.": "Un nom de bouteille ne peut pas se terminer par un point.",
        "The bottle name is too long (64 characters max).": "Le nom de la bouteille est trop long (64 caractères max).",
        "Windows programs are still running": "Des programmes Windows sont encore en cours d'exécution",
        "Stop them and quit, or leave them running? A game left running keeps playing without Highball — quit it from inside the game when you're done.":
            "Les arrêter et quitter, ou les laisser tourner ? Un jeu laissé ouvert continue sans Highball — quittez-le depuis le jeu quand vous avez terminé.",
        "Stop Everything & Quit": "Tout arrêter et quitter",
        "Leave Running & Quit": "Laisser tourner et quitter",
        "Stop All Windows Processes": "Arrêter tous les processus Windows",
        "Display scaling": "Mise à l'échelle de l'affichage",
        "Scales the Windows desktop and UI, 100% to 250%. Launchers and desktop apps follow it; many full-screen games set their own resolution and won't. Above 100% uses native Retina pixels, so heavy games may run slower.":
            "Met à l'échelle le bureau et l'interface Windows, de 100 % à 250 %. Les lanceurs et applications de bureau la suivent ; beaucoup de jeux en plein écran définissent leur propre résolution et l'ignorent. Au-delà de 100 %, le rendu utilise les pixels Retina natifs, donc les jeux exigeants peuvent ralentir.",
        "Applying display scaling": "Application de la mise à l'échelle",
        "Flaky": "Instable",
        "Known issues: ": "Problèmes connus : ",
        "Report a Problem…": "Signaler un problème…",
        "Report this problem…": "Signaler ce problème…",
        "Duplicate bottle": "Dupliquer la bouteille",
        "Repair bottle (re-run first boot)": "Réparer la bouteille (relancer le premier démarrage)",
        "Dependencies": "Dépendances",
        "Run a Windows program…": "Lancer un programme Windows…",
        "Run Windows Program…": "Lancer un programme Windows…",
        "— or drop any .exe or .msi on this window": "— ou déposez un .exe ou .msi sur cette fenêtre",
        "Choose a Windows program": "Choisir un programme Windows",
        "'%@' isn't a Windows program. You can drop .exe, .msi or .bat files here.":
            "« %@ » n'est pas un programme Windows. Vous pouvez déposer des fichiers .exe, .msi ou .bat ici.",
        "Installed": "Installée",
        "Epic Games": "Epic Games",
        "Connect Epic account…": "Connecter un compte Epic…",
        "Installs go through the open source Legendary client, so the Epic launcher's broken install flow is never involved.":
            "Les installations passent par le client libre Legendary, le mécanisme défaillant du launcher Epic n'est jamais utilisé.",
        "No games on this Epic account yet. Claimed games appear here.":
            "Aucun jeu sur ce compte Epic pour l'instant. Les jeux récupérés apparaîtront ici.",
        "Play with D3DMetal": "Jouer avec D3DMetal",
        "Play with DXMT": "Jouer avec DXMT",
        "Epic games launch with DXVK, the renderer that works for most of them. Right-click a game to try another.":
            "Les jeux Epic se lancent avec DXVK, le moteur qui fonctionne pour la plupart. Clic droit sur un jeu pour en essayer un autre.",
        "Connect your Epic account": "Connecter votre compte Epic",
        "1. Open Epic's sign-in page and log in.\n2. The page ends by showing an authorizationCode.\n3. Paste that code here.":
            "1. Ouvrez la page de connexion Epic et identifiez-vous.\n2. La page affiche à la fin un authorizationCode.\n3. Collez ce code ici.",
        "Open Epic sign-in page": "Ouvrir la page de connexion Epic",
        "Your password never touches Highball. The code is single use and connects through Legendary, the open source Epic client the Heroic launcher uses.":
            "Votre mot de passe ne passe jamais par Highball. Le code est à usage unique et la connexion utilise Legendary, le client Epic libre qu'utilise Heroic.",
        "Connect": "Connecter",
        "Connecting your Epic account": "Connexion de votre compte Epic",
        "Loading your Epic library…": "Chargement de votre bibliothèque Epic…",
        "Advanced": "Avancé",
        "DLL overrides": "Surcharges de DLL",
        "Extra Wine DLL overrides for this bottle, semicolon separated. Mods like Cyber Engine Tweaks need version=n,b.":
            "Surcharges de DLL Wine supplémentaires pour cette bouteille, séparées par des points-virgules. Des mods comme Cyber Engine Tweaks demandent version=n,b.",
        "Environment variables, one KEY=VALUE per line. Applied to everything launched in this bottle.":
            "Variables d'environnement, une paire CLE=VALEUR par ligne. Appliquées à tout ce qui se lance dans cette bouteille.",
        "Windows runtimes some games need. Install them when a game complains about a missing runtime or refuses to start.":
            "Des composants Windows dont certains jeux ont besoin. Installez-les quand un jeu se plaint d'un composant manquant ou refuse de démarrer.",
        "Steam crashed at a known spot — relaunching to resume the update":
            "Steam a planté à un endroit connu — relance pour reprendre la mise à jour",

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

        "DXVK async shader compilation (less stutter)": "Compilation asynchrone des shaders DXVK (moins de saccades)",
        "Frame rate cap": "Limite d’images par seconde",
        "Uncapped": "Illimité",
        "Games run with the bottle’s sync (msync is fastest). Opening the Steam window restarts Windows processes with sync off — its interface needs it.":
            "Les jeux utilisent la synchronisation de la bouteille (msync est la plus rapide). Ouvrir la fenêtre Steam redémarre les processus Windows sans synchronisation — son interface l’exige.",

        "Check for Updates…": "Rechercher les mises à jour…",

        "Your Steam library will appear here — install games inside Steam and they show up with compatibility verdicts.":
            "Votre bibliothèque Steam apparaîtra ici — installez des jeux dans Steam et ils s’afficheront avec leur verdict de compatibilité.",

        "Bottle settings": "Réglages de la bouteille",
        "Renderer, synchronization, Windows version…": "Rendu, synchronisation, version de Windows…",
        "More": "Plus",
        "Launchers": "Launchers",
        "Open": "Ouvrir",
        "Install": "Installer",
        "Graphics": "Graphismes",
        "Compatibility": "Compatibilité",
        "Your games will appear here": "Vos jeux apparaîtront ici",
        "Pour your first game": "Servez votre premier jeu",
        "Install games inside Steam — they show up with artwork and a compatibility verdict.": "Installez des jeux dans Steam — ils apparaissent avec leur visuel et leur verdict de compatibilité.",
        "Install Steam in this bottle to start playing your Windows library.": "Installez Steam dans cette bouteille pour jouer à votre bibliothèque Windows.",
        "Open Steam": "Ouvrir Steam",
        "Install Steam": "Installer Steam",
        "Delete this bottle? Its Windows drive and everything installed in it are removed.": "Supprimer cette bouteille ? Son disque Windows et tout ce qui y est installé seront effacés.",

        // Status pills
        "Verified": "Vérifié",
        "Reported": "Signalé",
        "Community": "Communauté",
        "Blocked — anti-cheat": "Bloqué — anti-cheat",
    ]
}
