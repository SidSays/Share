<html>
<p>While working on salesforce implementation, we should log exception somewhere in our system. This will help in identifying issue as well as we required it for enhancing our current system.
We can use salesforce debug log but this we have check each log record one by one to see some specific apex class issue.</p>

Let us see how to put custom exception logging in salesforce application. Below are steps to create custom logging :-
1. Create Custom Object
2. Create Apex class for Exception logging
3. Use that exception class in your code.

## 1. Create Custom Object:
Let us create new custom object in our salesforce application. Custom object name and fields details are as below image.

<img width="805" alt="image" src="https://github.com/SidSays/Share/assets/25760138/7a45c69a-65c4-49d1-8154-64bc697e2a57">

![image](https://github.com/SidSays/Share/assets/25760138/3c13067c-ec29-4e46-95a9-d43a9b647974)


## 2. Create an Apex class for Exception:
We have to create apex class which will extend Exception class. We will implement our code logic in this class.
Overloaded method LogException with different parameter is created. First method will log any anonymous exception and second method will log exception with record id for which exception is logged.
```

public class HandleCustomException extends Exception {
    public static void LogException(Exception e)
    {
        LogException(e,'');
    }
    // Log Exception in CustomException object. 
    // relatedToId : Case/object for which this error in logged.
    public static void LogException(Exception e,string relatedToId)
    {
        try
        {
		String stackTrace = e.getStackTraceString().substringBefore('\n');
		String className = stackTrace.substringAfter('.').substringBefore('.');	
            	String methodName = stackTrace.substringBefore(':').substringAfter(className).substringAfter('.');
                
            	//Governer Limit of executingQuery 
                String QueryLimit = '1. SOQL Queries used / SOQL Queries allowed: ' + Limits.getQueries() + '/' + Limits.getLimitQueries();
                String DMLimit = '2. Number of records queried so far /  Number allowed: ' + Limits.getDmlRows() + '/' + Limits.getLimitDmlRows();
                String DMLStat = '3. Number of DML statements used so far / Number allowed: ' +  Limits.getDmlStatements() + '/' + Limits.getLimitDmlStatements();   
                String CPUT = '4. Amount of CPU time (in ms) used so far / CPU usage time (in ms) allowed: ' + Limits.getCpuTime() + '/' + Limits.getLimitCpuTime();
              
            	//Log information in object
                CustomException__c exc = new CustomException__c();
            	exc.Related_To_Number__c=relatedToId;
                exc.Govt_Limit_in_Executing_Code__c = String.format('{0}\n{1}\n{2}\n{3}',new List<string>{QueryLimit, DMLimit,DMLStat,CPUT});
                exc.Exception_Message__c = e.getMessage();
                exc.Exception_Type__c = e.getTypeName();
                exc.Line_Number__c = e.getLineNumber();
                exc.StackTrace__c = e.getStackTraceString();
                exc.MethodName__c=methodName;
                exc.ClassName__c=className;
                database.insert(exc);            
        } 
        finally{
        }            
    } 
}
```

## 3. Use the exception class in your code: </h3>
Now our apex class is ready to use in our code to handle custom exceptions. For testing, let us create a test class for the above apex class.

```
@isTest
public class HandleCustomExceptionTest {
    @isTest
    public static void CreateAccount() {
        try {
            Account m = new Account();
            insert m;
        } catch (Exception e) {
            HandleCustomException.LogException(e);
        }    
    } 
}
```

## Summary :
<p>All apex errors can be logged in this custom object, we can create list views/reports/dashboard to monitor this on an admin dashboard.

</html>
