// usage:
// casperjs paypal.js pp_account.json m/d/y m/d/y
// pp_account.json should look like:
// {email: 'a@b.com', password: 'omigosh'}
var casper = require('casper').create();
var fs = require('fs'); 
var system = require('system');
var path = fs.absolute(system.args[4]);
var date_from = system.args[5];
var date_to = system.args[6];
var creds = eval('(' + fs.read(path) + ')');



var historyTable = '';

function scrapeBalance() {
    return document.querySelector('.balance').textContent;
}

function balanceTimeout() {
    console.log("timeout finding balance");
}

function scrapeHistory(){
    var history = [];
    var rows =  document.querySelectorAll('#transactionTable tr');
    var rowIndex;
    for(rowIndex = 1; rowIndex < rows.length; rowIndex++){
        var historyRow = [];
        var cols = rows[rowIndex].querySelectorAll('td');
        var colIndex;
        for (colIndex = 2; colIndex < cols.length; colIndex++) {
            historyRow.push(cols[colIndex].textContent.replace(/^\s+|\s+$/g, ''));
        }
        history.push(historyRow.join('\t'));
    }
    return history.join('\n');
}

/*
casper.start('http://127.0.0.1/PayPal.html', function() {
    historyTable = this.evaluate(scrapeHistory);
});
casper.waitUntilVisible('#transactionTable', function(){
    historyTable = this.evaluate(scrapeHistory);
});
*/
casper.start('http://www.paypal.com/us/home/', function() {
    this.fill('form[name="login_form"]', { login_email: creds.email, login_password: creds.password }, true);
});
casper.waitUntilVisible('.balance', function() {
    // do nothing?
}, balanceTimeout, 5000);

casper.thenOpen('https://history.paypal.com/us/cgi-bin/webscr?cmd=_history');

casper.waitUntilVisible('#transactionTable', function(){
    this.fill('form[name="history"]', {from_date: date_from, to_date: date_to, dateoption: 'dateselect'});
}, balanceTimeout, 5000);

casper.waitUntilVisible('#transactionTable', function(){
    historyTable = this.evaluate(scrapeHistory);
}, balanceTimeout, 5000);

casper.run(function() {
    this.echo(historyTable).exit();
});
