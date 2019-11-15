# Scheduled Virtual Machine Shutdown/Startup - Microsoft Azure
Scheduled VM shutdown and startup runbook for Azure Automation

This is a development version that originated from:

http://yetanotherdynamicsaxblog.blogspot.com/2017/10/use-azure-automation-to-start-and-stop.html

and before that from:
https://automys.com/library/asset/scheduled-virtual-machine-shutdown-startup-microsoft-azure

To contribute, please get in touch via email or a pull request!



*Text from http://yetanotherdynamicsaxblog.blogspot.com/2017/10/use-azure-automation-to-start-and-stop.html below:*

# Use Azure Automation to start and stop your VMs on a schedule
This post is long overdue, and I have been meaning to post it over a year ago.  I did present an early version of this script at the AXUG event in Stuttgart, but since then the API has changed around tags, and also it has become very easy to solve authentication using Run as Accounts. The code I am sharing here works on the latest version of the modules, and I hope it will keep working for years to come.

I few notes before I continue:
I base this script off from Automys own code, and it is heavily inspired by the commits done by other users out there in the community. I will refer to the project on GitHub where you will find contributors and authors. 
I've only tested and used the script for ARM Resources
I removed references to credentials and certificates and it relies on using "Run As Account". Setting up "Run As Account" in Azure is very easy and quick to do.
You will find the Feature branch here:
https://github.com/skaue/Azure-Automation-Scheduled-VM-Shutdown/tree/features/RunAsAccount

## Setup
I recommend starting by creating a new Automation Account. Yes, you can probably reuse an existing one, but creating a new account does not incur additional costs, and you can get this up and running fairly quick and easy just by following the steps in this blog post.

Make sure you select "Yes" on the option of creating "Azure Run as Account". Let it create all the artifacts and while you wait you can read the rest of this post.

When the Automation account is up and running, the next step is to create a new Runbook of type "PowerShell" - just straight up PowerShell, and no fancy stuff.

Then you grab the script from my feature branch based off the original trunk. You can either take the script from this post, or take the latest from GitHub. I probably won't maintain this blog post on any future updates of the script, but I might maintain the one on GitHub. I'll put a copy down below.

So with the script added as a PowerShell Runbook, and saved. Now you need to Schedule it. This is where a small cost may incur, because it is necessary to set the Runbook to run every hour. Yes - every hour. Using Automation for free only allow for a limited number of runs, and with the Runbook running every hour throughout the day, I believe it will stop running after 20 days - per month. There is a 500 minute limit per month for free, but the cost incurred when you exceed this is extremely low.

With the script running every hour you are ready to schedule "downtime". And this is easy.
You basically just either TAG the VM or the Resource Group holding a collection of VMs.

By TAG I mean you type on the downtime you want for your resource in the VALUE of a specific TAG. The script looks for a tag named "AutoShutdownSchedule". Example of value would be "20:00->06:00, Saturday, Sunday", and you can probably guess when the server will be shutdown with that value... That is correct, all weekdays between 8 pm at night and 6 am in the morning. You can imagine the flexibility this gives.

### Schedule Tag Examples
The easiest way to write the schedule is to say it first in words as a list of times the VM should be shut down, then translate that to the string equivalent. Remember, any time period not defined as a shutdown time is online time, so the runbook will start the VMs accordingly. Let’s look at some examples:

| Description | Tag value |
| --- | --- |
| Shut down from 10PM to 6 AM UTC every day | 10pm -> 6am |
| Shut down from 10PM to 6 AM UTC every day (different format, same result as above) | 22:00 -> 06:00 |
| Shut down from 8PM to 12AM and from 2AM to 7AM UTC every day (bringing online from 12-2AM for maintenance in between) | 8PM -> 12AM, 2AM -> 7AM |
| Shut down all day Saturday and Sunday (midnight to midnight) | Saturday, Sunday |
| Shut down from 2AM to 7AM UTC every day and all day on weekends | 2:00 -> 7:00, Saturday, Sunday |
| Shut down on Christmas Day and New Year’s Day | December 25, January 1 |
| Shut down from 2AM to 7AM UTC every day, and all day on weekends, and on Christmas Day | 2:00 -> 7:00, Saturday, Sunday, December 25 |
| Shut down always – I don’t want this VM online, ever | 0:00 -> 23:59:59 |
 

## Added Features
In addition, the script is inspired by other nice ideas from the community, like providing a TimeZone for your schedule, just to ensure your 8 pm is consistent to when the script interprets the value.

Another feature added is the ability to use a "NeverStart" value keyword, to enforce the resource does not start. You can use this to schedule automatic shutdown that does not trigger startup again after the schedule ends. Example is the value "20:00->21:00,NeverStart". This would stop the resource at 8 pm, and when the RunBook runs again at 9 pm, the resource will not start even though the schedule has ended.

Finally, I want to comment the added feature of disabling the schedule without removing the schedule. If you provide an additional tag with the name "AutoShutdownDisabled" with a value of Yes/1/True. This means you can keep the schedule and temporarily disable the shutdown schedule altogether.
