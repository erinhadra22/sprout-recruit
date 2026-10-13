import Foundation

extension Store {
    func seedDemo() throws {
        let names = ["Alex Morgan","Jamie Bennett","Taylor Brooks","Jordan Ellis","Cameron Reed","Avery Collins","Riley Parker","Morgan Hayes","Casey Jordan","Quinn Harper","Reese Sullivan","Drew Emerson","Skyler Blake","Hayden Monroe","Rowan Mitchell","Peyton Ross","Sage Anderson","Finley Carter","Emery Lawson","Blair Mason","Kendall Foster","Logan Spencer","Sydney Warren","Charlie Quinn"]
        let offices = ["Oak & Field Realty","Westhaven Properties","Cedar House Realty","Northline Real Estate","Hill Country Collective","Lakeside Property Group"]
        let cities = ["Austin","Round Rock","Cedar Park","Austin","Leander","Georgetown","Dallas","Fort Worth"]
        let categories = ["Ready to Move","Ready to Move","Recent Co-Broker","Decreasing Sales","Trouble at Current Office","Ready to Move"]
        let statuses = ["Contacted","Connected","Meeting scheduled","Identified","","Meeting held","Negotiating","Contacted","","Identified","Contract out","","Recruited","Not interested","Contacted","","Connected","Identified","Lost","","","","",""]
        for i in names.indices {
            let id = String(format:"sample-%02d",i+1), volume = 2340000 + i * 287350
            let units = 6+i, category = categories[i % categories.count]
            let current = category == "Ready to Move" ? 0 : (i % 4)+1
            var transactions: [Record] = []
            for j in 0..<units {
                transactions.append(["id":"\(id)-tx-\(j)","date":Store.plusDays(-(j * max(1, 330 / units) + i)),"activity":"Closed sale","price":Double(volume)/Double(units),"address":"\(100+j*13) Example \(["Oak Lane","Creek Drive","Ridge Road"][j%3])","city":cities[i%cities.count],"side":j%3==0 ? "List-side" : "Buy-side","property":"Single family","sample":true])
            }
            let change = i%3 == 0 ? -(18+i) : 8+i*3
            var history: [Record] = []
            for y in 0..<6 {
                let annualVolume = Double(volume) * (0.52 + Double(y) * 0.09)
                let officeIndex = (i + (y < 3 ? 1 : 0)) % offices.count
                history.append(["year":2021+y,"volume":annualVolume,"buy":0.58,"office":offices[officeIndex]])
            }
            let signals: [Record] = [
                ["label":category == "Ready to Move" ? "No active or pending listings" : "Recent business activity","detail":category == "Ready to Move" ? "The sample record has no active or pending business." : "A recent transaction offers context for a conversation.","kind":"timing"],
                ["label":change < 0 ? "Production below last year" : "Production momentum","detail":"Illustrative LTM volume change of \(change)%.","kind":"production"],
                ["label":category == "Trouble at Current Office" ? "Office agent count declining" : "Established local business","detail":"Sample evidence for layout and workflow testing; not a verified recruiting signal.","kind":"context"]]
            let r: Record = ["id":id,"name":names[i],"office":offices[i%offices.count],"city":cities[i%cities.count],"email":"\(names[i].lowercased().replacingOccurrences(of:" ",with:"."))@example.com","phone":"(512) 555-\(String(format:"%04d",100+i))","source":"Fictional sample","manual":false,"status":statuses[i],"statusAt":Store.plusDays(-i-2),"assignee":"Erin Hadra","liked":i%7==0,"disposition":"","volume":volume,"units":units,"change":change,"years":3+i%13,"officeYears":1+i%6,"move":category == "Ready to Move" ? "High" : ["Moderate","Low","High"][i%3],"growth":["Moderate","High","Low"][i%3],"category":category,"active":current,"pending":0,"dom":24+i,"closeRatio":97.8,"rentals":i%6,"mls":"SAMPLE","license":"DEMO-\(1000+i)","history":history,"transactions":transactions,"signals":signals,"createdAt":Store.plusDays(-21)]
            try put("agents",r)
            if !statuses[i].isEmpty {
                try put("activities",["id":"seed-activity-\(i)","agentId":id,"kind":"note","title":"Sample recruiting context","body":"Fictional record for exploring the local workflow. Add your own notes here; no live agent data has been imported.","date":Store.plusDays(-i%7)+"T10:00:00","author":"Erin Hadra","pinned":false])
            }
            if i < 9 {
                try put("tasks",["id":"seed-task-\(i)","agentId":id,"title":["First conversation","Follow up after introduction","Prepare for recruiting call"][i%3],"dueDate":Store.plusDays(i-3),"type":["Call","Message","Meeting"][i%3],"priority":i%3==0 ? "High" : "Medium","description":"Sample task — use this to test your workflow.","assignee":"Erin Hadra","repeatDays":0,"completed":false,"createdAt":Store.now()])
            }
            if i < 12 {
                let titles = ["Newly high potential to move","Now has no active or pending","Recent co-broker","Lagging the market","No recent real estate activity","Highest closed sale"]
                try put("alerts",["id":"sample-alert-\(i)","agentId":id,"title":titles[i%6],"body":"Illustrative business event. Review the profile and choose a thoughtful next step.","date":Store.plusDays(-i%5),"dismissed":false])
            }
        }
        try seedWorkspace()
        try put("watchlists",["id":"sample-watchlist","name":"Austin conversations","agentIds":["sample-01","sample-02","sample-04"],"createdAt":Store.now()])
    }
    func seedWorkspace() throws {
        try put("settings",["id":"preferences","minVolume":2000000,"maxVolume":0,"minYears":1,"maxYears":0,"minUnits":0,"maxUnits":0,"minPrice":0,"maxPrice":0,"cities":[],"dailyLimit":20,"mustVolume":true,"mustYears":true,"mustUnits":false,"mustPrice":false])
        try put("settings",["id":"workspace","name":"Erin Hadra","company":"Sprout Realty","role":"Head of Recruiting","columns":["office","volume","city","move","status","lastInteraction"],"instructions":"Keep drafts brief, warm and personal. Review all claims before using a draft."])
    }

}
