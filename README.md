RetainUIKit is a simple UI framework that enables declarative construction of iOS interfaces with automatic data binding. It relies on retain observation hooks so UI elements update automatically when data changes, minimizing boilerplate and manual state management.

[Video](https://www.youtube.com/shorts/ndoQJVEpxoo)

```swift
import UIKit

class ViewController: UIViewController {

    class Model {
        var counter = 0
    }
    
    var model = Model()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.view = padding(.init(top: 100, left: 20, bottom: 20, right: 20)) {
            stack { _ in
                label(title: { "Counter \(self.model.counter)" })
                button(title: {"Click!"}, onTap: {
                    self.model.counter = self.model.counter + 1
                })
            }
        }
    }
}
```
