// Backend script to scrape Momentums for data and pipe it to the Zenon Wall
// Add this .dart to znn_cli_dart-master and run with the params below
// Usage: wall_engine.dart -u ws://10.0.0.192:35998 test

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:sanitize_html/sanitize_html.dart' show sanitizeHtml;
import 'package:path/path.dart' as p;
import 'package:html/parser.dart';
import 'package:process_run/shell.dart';
import 'package:znn_sdk_dart/znn_sdk_dart.dart';

import 'init_znn.dart';

var path = 'C:\\Users\\user\\web\\sol-sanctum.github.io\\';

Future<int> main(List<String> args) async {
  return initZnn(args, handleCli);
}

void buildAndPush(String path, var height) async {
  // Jekyll Build project
  var shell = Shell();
  shell = shell.cd(path);
  var jekyll = 'C:\\Ruby31-x64\\bin\\jekyll';

  try {
    await shell.run('''
    ${jekyll} build
    ''');
  } on ShellException catch (_) {
    print("Jekyll Build error: ${_}");
  }


  try {
    await shell.run('''
    git add .
    git commit -m "Update for Momentum ${height}"
    git push
    ''');
  } on ShellException catch (_) {
    print("Git error: ${_}");
  }

}

String formatHTML(String args) {
  final parsedJson = jsonDecode(args);

  DateTime date =
      DateTime.fromMillisecondsSinceEpoch(int.parse(parsedJson['time']) * 1000)
          .toUtc();
  var d2 = date.toString().substring(0, date.toString().length - 5);

  var sanitizedData = sanitizeHtml(parsedJson['data']);
  var output = "\t\t\t\t"
      '<a href="https://explorer.zenon.network/transaction/${parsedJson["hash"]}"><span style="color:grey;">${d2} UTC:</span> ${sanitizedData}</a><br>'
      "\n";
  print(output);
  return output;
}

void updateWall(List messages) {
  // Parse HTML doc, update correct section

  File wall = File(path + "wall.html");
  var wallContent = wall.readAsStringSync();
  var document = parse(wallContent);

  var x = document.outerHtml.split('<div class="excerpt">');
  var excerpt = '<div class="excerpt">' "\n";

  x[0] = x[0].replaceAll("<html><head></head><body>", "");
  x[1] = x[1].replaceAll("</body></html>", "");

  var newDocument = x[0] + excerpt;

  messages.forEach((line) {
    newDocument += line;
  });

  newDocument += x[1];
  //print(newDocument);

  // Write newDocument to wall.html
  wall.writeAsString('$newDocument');
}

List extractMomentumData(DetailedMomentumList getDetailedMomentumsByHeight) {
  List messages = [];

  getDetailedMomentumsByHeight.list!.forEach((element) {
    if (element.momentum.content.length > 0) {
      //print("${element.momentum.height} has ${element.momentum.content.length} transactions");
      try {
        element.blocks.forEach((block) {
          if (block.blockType == 2) {
            String data = '';
            if (block.data.length > 0) {
              block.data.forEach((element) {
                data += String.fromCharCode(element);
              });

              if (data[0] == 'Z' && data[1] == 'W') {
                //if (data[0] == 'Z' && data[1] == 'N' && data[2] == 'N') {
                //String sub = data.substring(4, data.length);
                String sub = data.substring(3, data.length);

                var jsonData =
                    '{ "hash": "${block.hash}", "time": "${block.confirmationDetail!.momentumTimestamp}", "data": "${sub}" }';
                messages.add(formatHTML(jsonData));
              }
            }
          }
        });
      } catch (e) {
        print("Exception was caught while trying to read data: ${e}");
      }
    }
  });
  return messages;
}

Future<void> handleCli(List<String> args) async {
  final Zenon znnClient = Zenon();

  while (true) {
    List messages = [];

    //Get Current Momentum
    Momentum currentFrontierMomentum =
        await znnClient.ledger.getFrontierMomentum();
    print(
        'Current Momentum height: ${currentFrontierMomentum.height.toString()} || timestamp: ${DateTime.fromMillisecondsSinceEpoch(currentFrontierMomentum.timestamp * 1000)}');
    int height = currentFrontierMomentum.height;

    //Get Last Known Momentum
    var filePath = p.join(Directory.current.path, '.', 'lastMomentum.txt');
    File file = File(filePath);
    var fileContent = file.readAsStringSync();
    var difference = height - int.parse(fileContent);
    print("Last Momentum:${fileContent} (behind by ${difference})");

    //Due to retrieval limitation with ledger.getDetailedMomentumsByHeight() or client,
    // limit queries to 200 momentums (max ~250)
    if (difference <= 200) {
      DetailedMomentumList getDetailedMomentumsByHeight = await znnClient.ledger
          .getDetailedMomentumsByHeight(int.parse(fileContent) + 1, difference);
      messages += await extractMomentumData(getDetailedMomentumsByHeight);
      file.writeAsString('$height');
    } else {
      var start = int.parse(fileContent) + 1;
      var loops = (start / 200).floor();
      var remainder = start % 200;

      for (var i = 0; i < loops; i++) {
        DetailedMomentumList getDetailedMomentumsByHeight =
            await znnClient.ledger.getDetailedMomentumsByHeight(start, 200);
        messages += await extractMomentumData(getDetailedMomentumsByHeight);
        start += 200;
      }
      DetailedMomentumList getDetailedMomentumsByHeight =
          await znnClient.ledger.getDetailedMomentumsByHeight(start, remainder);
      messages += await extractMomentumData(getDetailedMomentumsByHeight);
      file.writeAsString('$height');
    }

    if (messages.length > 0) {
      updateWall(messages);
      buildAndPush(path, height);
    }

    print("[-] Sleeping 120 seconds...");
    await new Future.delayed(const Duration(seconds: 120));
  }
}
