with open('flutter_app/lib/home_page.dart', 'r', encoding='utf-8') as f:
    content = f.read()

old = """      // Helper: check if a logo fits in a top row given current logos in that row and bottom count
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
      }"""

new = """      // Helper: check if a logo fits in a top row given the set's actual bottom logos and current top logos
      bool fitsInTop(List<LogoItem> bottomLogos, List<LogoItem> currentTop, LogoItem nextLogo) {
        final testTop = [...currentTop, nextLogo];
        // Calculate total width needed for this set's top row
        // Top row starts from left, must stop before corner logo
        double totalWidth = 0;
        // First add THIS SET'S bottom logos' widths to get start position
        for (int i = 0; i < bottomLogos.length; i++) {
          final logoW = logoWidths[allLogos.indexOf(bottomLogos[i])];
          totalWidth += logoW + (i > 0 ? gapPx : 0);
        }
        // Now add THIS SET'S top logos
        for (int i = 0; i < testTop.length; i++) {
          final logoW = logoWidths[allLogos.indexOf(testTop[i])];
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
      }"""

if old in content:
    content = content.replace(old, new)
    print("Fixed fitsInTop function signature")
else:
    print("Could not find fitsInTop function")

# Now fix the calls to fitsInTop
old_call_a = """        // Try Set A top
        if (!aTopFull && idx < allLogos.length) {
          if (fitsInTop(setATop, setABottom.length, allLogos[idx])) {
            setATop.add(allLogos[idx++]);
          } else {
            aTopFull = true;
          }
        }"""

new_call_a = """        // Try Set A top
        if (!aTopFull && idx < allLogos.length) {
          if (fitsInTop(setABottom, setATop, allLogos[idx])) {
            setATop.add(allLogos[idx++]);
          } else {
            aTopFull = true;
          }
        }"""

if old_call_a in content:
    content = content.replace(old_call_a, new_call_a)
    print("Fixed Set A fitsInTop call")
else:
    print("Could not find Set A fitsInTop call")

old_call_b = """        // Try Set B top
        if (!bTopFull && idx < allLogos.length) {
          if (fitsInTop(setBTop, setBBottom.length, allLogos[idx])) {
            setBTop.add(allLogos[idx++]);
          } else {
            bTopFull = true;
          }
        }"""

new_call_b = """        // Try Set B top
        if (!bTopFull && idx < allLogos.length) {
          if (fitsInTop(setBBottom, setBTop, allLogos[idx])) {
            setBTop.add(allLogos[idx++]);
          } else {
            bTopFull = true;
          }
        }"""

if old_call_b in content:
    content = content.replace(old_call_b, new_call_b)
    print("Fixed Set B fitsInTop call")
else:
    print("Could not find Set B fitsInTop call")

with open('flutter_app/lib/home_page.dart', 'w', encoding='utf-8') as f:
    f.write(content)

print("\nDone!")