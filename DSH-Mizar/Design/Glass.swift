//
//  Glass.swift
//  DSH-Mizar
//
//  Liquid Glass on iOS 26, and a plain material everywhere else.
//
//  One rule: glass is for what floats above the content -- the bars, the
//  composer, the dock of pending requests, the sidebar's controls. Content stays
//  solid. A screen made of glass is a screen of reflections; the effect reads as
//  grand precisely because there is so little of it.
//
//  The app runs back to iOS 18, where `glassEffect` does not exist: it arrived
//  with iOS 26, together with `GlassEffectContainer`, `.buttonStyle(.glass)`
//  and `scrollEdgeEffectStyle`. Each of those is therefore behind an
//  availability check, with a material -- the thing glass replaced -- standing
//  in below it. The two paths are not meant to look identical: a phone that
//  cannot render glass should not be shown an imitation of it.
//

import SwiftUI

// MARK: - Surfaces

extension View {
    /// A capsule of glass.
    func liquidCapsule(interactive: Bool = false) -> some View {
        liquidSurface(in: Capsule(), interactive: interactive)
    }

    /// Glass in any shape, or nothing at all.
    ///
    /// - Parameters:
    ///   - shape: what to pour it into.
    ///   - tint: a colour the glass carries, for surfaces that mean something
    ///     (an approval, a question).
    ///   - interactive: whether the glass answers a touch -- it swells and
    ///     catches the light under the finger. For controls, not for panels.
    ///   - condition: when false the view is returned untouched, which is how a
    ///     control that fills itself with a solid colour avoids a layer of glass
    ///     underneath it.
    /// - Returns: the surfaced view.
    @ViewBuilder
    func liquidSurface<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        when condition: Bool = true,
    ) -> some View {
        if condition {
            if #available(iOS 26.0, *) {
                glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
            } else {
                materialSurface(in: shape, tint: tint)
            }
        } else {
            self
        }
    }

    /// A continuous rounded rectangle of glass.
    func liquidCard(radius: CGFloat = Theme.Radius.card, tint: Color? = nil) -> some View {
        liquidSurface(in: RoundedRectangle(cornerRadius: radius, style: .continuous), tint: tint)
    }

    /// What a surface becomes where glass is not available.
    ///
    /// The material is the system's own translucent layer, so it follows the
    /// appearance and the accessibility contrast setting without being told to.
    /// The hairline and the shadow are what keep a translucent panel legible
    /// over a photograph, which is the case a material alone does not cover.
    private func materialSurface<S: Shape>(in shape: S, tint: Color?) -> some View {
        self
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay { shape.fill(tint ?? Color.clear) }
            }
            .clipShape(shape)
            .overlay {
                shape
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
    }
}

// MARK: - Containers

/// Groups neighbouring glass so it blends instead of meeting in a seam, and so
/// pieces with a shared `glassEffectID` morph into one another.
///
/// Below iOS 26 there is nothing to group: the views are already separate, and
/// passing them through unchanged is the whole of the behaviour there.
struct GlassRow<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

/// A round control on glass: the sidebar toggle, refresh, jump-to-latest.
struct GlassCircleLabel<Content: View>: View {
    var size: CGFloat = 40
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: size, height: size)
            .contentShape(.circle)
            .liquidSurface(in: Circle(), interactive: true)
    }
}

// MARK: - Buttons and scroll edges

extension View {
    /// The glass button styles, or the bordered ones that came before them.
    ///
    /// `.buttonStyle(.glass)` and `.glassProminent` are iOS 26. Below it the
    /// system's own bordered pair is used rather than a hand-drawn stand-in:
    /// it already answers to the tint, the enabled state and Dynamic Type, and
    /// a copy of it would be a copy that drifts.
    @ViewBuilder
    func mizarGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// The soft fade a scroll view gets at its edge, where iOS 26 offers one.
    ///
    /// Below iOS 26 there is no equivalent to fall back to -- the effect belongs
    /// to the new scroll edge rendering rather than to a modifier that can be
    /// reproduced -- so the scroll view is simply left as it was.
    @ViewBuilder
    func mizarScrollEdgeEffect(_ edges: Edge.Set) -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            self
        }
    }
}
