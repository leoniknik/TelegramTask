import Foundation
import UIKit
import ComponentFlow
import Display

public extension Transition.Animation.Curve {
    init(_ curve: ContainedViewLayoutTransitionCurve) {
        switch curve {
        case .linear:
            self = .easeInOut
        case .easeInOut:
            self = .easeInOut
        case .custom:
            self = .spring
        case .customSpring:
            self = .spring
        case .spring:
            self = .spring
        }
    }
    
    var containedViewLayoutTransitionCurve: ContainedViewLayoutTransitionCurve {
        switch self {
            case .easeInOut:
                return .easeInOut
            case .spring:
                return .spring
        }
    }
}

public extension Transition {
    init(_ transition: ContainedViewLayoutTransition) {
        switch transition {
        case .immediate:
            self.init(animation: .none)
        case let .animated(duration, curve):
            self.init(animation: .curve(duration: duration, curve: Transition.Animation.Curve(curve)))
        }
    }
    
    var containedViewLayoutTransition: ContainedViewLayoutTransition {
        switch self.animation {
            case .none:
                return .immediate
            case let .curve(duration, curve):
                return .animated(duration: duration, curve: curve.containedViewLayoutTransitionCurve)
        }
    }
}