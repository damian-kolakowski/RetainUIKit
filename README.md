RetainUIKit is a lightweight UI framework for iOS that enables declarative construction of interfaces with automatic data binding. Built entirely through “vibe coding,” the project embraces rapid experimentation and intuition-driven design rather than rigid architectural planning. It leverages retain-based observation hooks to automatically propagate state changes to UI components, allowing views to stay in sync with underlying data without manual updates or verbose binding code.

<img src="https://raw.githubusercontent.com/damian-kolakowski/RetainUIKit/refs/heads/main/demo.png" width="200px"/>

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
