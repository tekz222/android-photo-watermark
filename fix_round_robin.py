with open('flutter_app/lib/home_page.dart', 'r', encoding='utf-8') as f:
    content = f.read()

old = """    } else {
      // ALTERNATING MODE: round-robin fill bottom rows first, then top rows
      // Each set's bottom row fills independently to its max capacity
      // Then each set's top row fills independently (respecting corner logo)
      // Ensure Set A and B exist
      if (_logoSetA == null) _logoSetA = LogoSet(bottomLogos: [], topLeftLogos: []);
      if (_logoSetB == null) _logoSetB = LogoSet(bottomLogos: [], topLeftLogos: []);

      // Calculate max capacity for EACH bottom row independently (using corner space)
      // Both sets use the same calculation since they have same layout
      final maxBottomA = _fitCountWithCorner(0, mainSectionWidth, cornerSectionWidth);
      final maxBottomB = maxBottomA; // Same layout, same capacity

      // Calculate max capacity for EACH top row independently
      // Each set starts fresh at index 0 for top row calculation
      // (Actual top capacity will be calculated after bottom rows are filled)
      // maxTopA is not used directly; actualMaxTopA is calculated after bottom fill

      // Round-robin fill bottom rows: A bottom, B bottom, A bottom, B bottom...
      final setABottom = <LogoItem>[];
      final setBBottom = <LogoItem>[];
      final setATop = <LogoItem>[];
      final setBTop = <LogoItem>[];

      int idx = 0;
      int placedBottomA = 0;
      int placedBottomB = 0;

      // Fill bottom rows round-robin until both are full or no more logos
      while (idx < allLogos.length && (placedBottomA < maxBottomA || placedBottomB < maxBottomB)) {
        // Add to Set A bottom if not full
        if (placedBottomA < maxBottomA && idx < allLogos.length) {
          setABottom.add(allLogos[idx++]);
          placedBottomA++;
        }
        // Add to Set B bottom if not full
        if (placedBottomB < maxBottomB && idx < allLogos.length) {
          setBBottom.add(allLogos[idx++]);
          placedBottomB++;
        }
      }

      // Now fill top rows round-robin: A top, B top, A top, B top...
      // Each set's top row capacity depends on how many bottom logos it has
      // (because _fitCountTop uses startIdx to know which logos are already placed)
      // But we calculate capacity based on the actual bottom count for each set
      int placedTopA = 0;
      int placedTopB = 0;

      // Calculate actual top capacity for each set based on their bottom count
      final actualMaxTopA = _fitCountTop(placedBottomA, logoWidths);
      final actualMaxTopB = _fitCountTop(placedBottomB, logoWidths);

      while (idx < allLogos.length && (placedTopA < actualMaxTopA || placedTopB < actualMaxTopB)) {
        // Add to Set A top if not full
        if (placedTopA < actualMaxTopA && idx < allLogos.length) {
          setATop.add(allLogos[idx++]);
          placedTopA++;
        }
        // Add to Set B top if not full
        if (placedTopB < actualMaxTopB && idx < allLogos.length) {
          setBTop.add(allLogos[idx++]);
          placedTopB++;
        }
      }

      final totalPlaced = setABottom.length + setBBottom.length + setATop.length + setBTop.length;
      final overflow = totalPlaced < allLogos.length;

      setState(() {
        _logoSetA = _logoSetA!.copyWith(
          bottomLogos: setABottom,
          topLeftLogos: setATop,
        );
        _logoSetB = _logoSetB!.copyWith(
          bottomLogos: setBBottom,
          topLeftLogos: setBTop,
        );
        // Also clear logoSets when in dual-set mode
        _p.logoSets = [];
      });

      if (overflow && mounted) {
        _snack(
          'Ambos os conjuntos estão cheios! ${allLogos.length - totalPlaced} logo(s) não couberam. '
          'Reduza o tamanho das logos.',
          backgroundColor: const Color(0xFFB71C1C),
        );
        return false;
      }
    }"""

new = """    } else {
      // ALTERNATING MODE: round-robin fill bottom rows first, then top rows
      // DYNAMIC CAPACITY: Check if each logo fits in its target set's row
      // using the ACTUAL logo widths that set will receive (not assuming index 0)
      // Ensure Set A and B exist
      if (_logoSetA == null) _logoSetA = LogoSet(bottomLogos: [], topLeftLogos: []);
      if (_logoSetB == null) _logoSetB = LogoSet(bottomLogos: [], topLeftLogos: []);

      // Track which logos go to each set for capacity calculation
      final setABottom = <LogoItem>[];
      final setBBottom = <LogoItem>[];
      final setATop = <LogoItem>[];
      final setBTop = <LogoItem>[];

      int idx = 0;

      // Helper: check if a logo fits in a bottom row given current logos in that row
      bool fitsInBottom(List<LogoItem> currentBottom, LogoItem nextLogo) {
        final testBottom = [...currentBottom, nextLogo];
        // Calculate total width needed for this set's bottom row
        double totalWidth = 0;
        for (int i = 0; i < testBottom.length; i++) {
          final logoW = logoWidths[allLogos.indexOf(testBottom[i])];
          totalWidth += logoW + (i > 0 ? gapPx : 0);
        }
        // Check if fits in main section (80%) or can use corner section
        final mainSectionRightEdge = photoWidth * 0.8 - edgeMarginPx;
        final cornerSectionRightEdge = photoWidth - edgeMarginPx;
        bool usedCorner = false;
        double currentWidth = 0;
        for (int i = 0; i < testBottom.length; i++) {
          final logoW = logoWidths[allLogos.indexOf(testBottom[i])];
          final neededWidth = currentWidth + logoW + (i > 0 ? gapPx : 0);
          if (neededWidth <= mainSectionRightEdge) {
            currentWidth = neededWidth;
          } else if (!usedCorner && neededWidth <= cornerSectionRightEdge) {
            final cornerSectionLeftEdge = photoWidth * 0.8 - edgeMarginPx;
            if (neededWidth >= cornerSectionLeftEdge && neededWidth <= cornerSectionRightEdge) {
              currentWidth = neededWidth;
              usedCorner = true;
            } else {
              return false;
            }
          } else {
            return false;
          }
        }
        return true;
      }

      // Helper: check if a logo fits in a top row given current logos in that row and bottom count
      bool fitsInTop(List<LogoItem> currentTop, int bottomCount, LogoItem nextLogo) {
        final testTop = [...currentTop, nextLogo];
        // Calculate total width needed for this set's top row
        // Top row starts from left, must stop before corner logo
        // Corner logo position: photoWidth - cornerMarginRight - cornerWidth
        // We'll use _fitCountTop logic: startIdx = bottomCount, check each logo
        double totalWidth = 0;
        // First add bottom logos' width to get start position
        for (int i = 0; i < bottomCount; i++) {
          final logoW = logoWidths[i]; // bottom logos start from 0
          totalWidth += logoW + (i > 0 ? gapPx : 0);
        }
        // Now add top logos
        for (int i = 0; i < testTop.length; i++) {
          final logoW = logoWidths[bottomCount + i];
          totalWidth += logoW + (i > 0 ? gapPx : 0);
        }
        // Check against corner logo position (approximate)
        final cornerLogo = _cornerLogo;
        double maxX;
        if (cornerLogo != null) {
          // Approximate corner logo left edge
          maxX = photoWidth * 0.8 - edgeMarginPx; // Conservative: main section only
        } else {
          maxX = photoWidth - edgeMarginPx;
        }
        return totalWidth <= maxX;
      }

      // ===== PHASE 1: Fill bottom rows round-robin with DYNAMIC fitting =====
      bool aBottomFull = false;
      bool bBottomFull = false;

      while (idx < allLogos.length && (!aBottomFull || !bBottomFull)) {
        // Try Set A bottom
        if (!aBottomFull && idx < allLogos.length) {
          if (fitsInBottom(setABottom, allLogos[idx])) {
            setABottom.add(allLogos[idx++]);
          } else {
            aBottomFull = true;
          }
        }
        // Try Set B bottom
        if (!bBottomFull && idx < allLogos.length) {
          if (fitsInBottom(setBBottom, allLogos[idx])) {
            setBBottom.add(allLogos[idx++]);
          } else {
            bBottomFull = true;
          }
        }
        // If both full, break
        if (aBottomFull && bBottomFull) break;
      }

      // ===== PHASE 2: Fill top rows round-robin with DYNAMIC fitting =====
      bool aTopFull = false;
      bool bTopFull = false;

      while (idx < allLogos.length && (!aTopFull || !bTopFull)) {
        // Try Set A top
        if (!aTopFull && idx < allLogos.length) {
          if (fitsInTop(setATop, setABottom.length, allLogos[idx])) {
            setATop.add(allLogos[idx++]);
          } else {
            aTopFull = true;
          }
        }
        // Try Set B top
        if (!bTopFull && idx < allLogos.length) {
          if (fitsInTop(setBTop, setBBottom.length, allLogos[idx])) {
            setBTop.add(allLogos[idx++]);
          } else {
            bTopFull = true;
          }
        }
        // If both full, break
        if (aTopFull && bTopFull) break;
      }

      final totalPlaced = setABottom.length + setBBottom.length + setATop.length + setBTop.length;
      final overflow = totalPlaced < allLogos.length;

      setState(() {
        _logoSetA = _logoSetA!.copyWith(
          bottomLogos: setABottom,
          topLeftLogos: setATop,
        );
        _logoSetB = _logoSetB!.copyWith(
          bottomLogos: setBBottom,
          topLeftLogos: setBTop,
        );
        // Also clear logoSets when in dual-set mode
        _p.logoSets = [];
      });

      if (overflow && mounted) {
        _snack(
          'Ambos os conjuntos estão cheios! ${allLogos.length - totalPlaced} logo(s) não couberam. '
          'Reduza o tamanho das logos.',
          backgroundColor: const Color(0xFFB71C1C),
        );
        return false;
      }
    }"""

if old in content:
    content = content.replace(old, new)
    with open('flutter_app/lib/home_page.dart', 'w', encoding='utf-8') as f:
        f.write(content)
    print("Successfully rewrote alternating mode with DYNAMIC capacity checking!")
else:
    print("Could not find the exact text to replace")
    idx = content.find('ALTERNATING MODE: round-robin fill bottom rows')
    if idx >= 0:
        print(f"Found at index {idx}:")
        print(repr(content[idx:idx+200]))
    else:
        print("Not found at all")