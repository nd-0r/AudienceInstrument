import UIKit

let num: Double = 3

class Shape {
    var numSides = 0
    let name = "Shape"

    init(numSides: Int = 0) {
        self.numSides = numSides
    }

    func describe() -> String {
        return """
        this is a \(name) with \(numSides) sides
        """
    }
}

class Square: Shape {
    init() {
        super.init(numSides: 4)
    }

    override func describe() -> String {
        return """
        this is a Square with \(self.numSides) sides
        """
    }
}

let sq = Square()
print(sq.describe())
