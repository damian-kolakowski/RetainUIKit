import UIKit

class ViewController: UIViewController {

    class Model {
        var counter = 0
    }
    
    var model = Model()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.view = padding(.init(top: 100, left: 20, bottom: 20, right: 10)) {
            stack { _ in
                label(title: { "Counter \(self.model.counter)" })
                button(title: {"Click!"}, onTap: {
                    self.model.counter = self.model.counter + 1
                })
            }
        }
        
        self.view.backgroundColor = .white
    }
}

